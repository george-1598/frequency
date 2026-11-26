-- Tuned In: full database setup (run once in the Supabase SQL editor).
-- Everything is prefixed ti_, so it sits next to the guess-who game safely.

-- Tuned In: rooms, rounds, secret targets and guesses.
--
-- Everything goes through functions (security definer) that enforce the rules
-- and hide secrets: the target is only shown to the round's psychic until the
-- reveal, and other players' guesses only appear at the reveal. Clients learn
-- that something changed through Realtime on `room_ticks` (one tiny row per
-- room), then fetch the filtered state with get_room_state().
--
-- Players sign in anonymously (no account), so auth.uid() identifies a phone.

-- ---------------------------------------------------------------- tables

create table public.ti_cards (
  id serial primary key,
  left_label text not null,
  right_label text not null
);

create table public.ti_rooms (
  code text primary key,
  host uuid not null,
  status text not null default 'lobby' check (status in ('lobby', 'playing', 'finished')),
  round int not null default 0,
  rounds_total int not null default 0,
  rounds_per_player int not null default 2 check (rounds_per_player between 1 and 5),
  precision int not null default 7 check (precision in (4, 7, 10)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ti_players (
  room text not null references public.ti_rooms (code) on delete cascade,
  user_id uuid not null,
  name text not null check (length(name) between 1 and 24),
  seat int not null,
  score numeric not null default 0,
  last_seen timestamptz not null default now(),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (room, user_id)
);

create table public.ti_room_cards (
  id bigint generated always as identity primary key,
  room text not null references public.ti_rooms (code) on delete cascade,
  left_label text not null check (length(left_label) between 1 and 40),
  right_label text not null check (length(right_label) between 1 and 40),
  added_by uuid not null
);

create table public.ti_rounds (
  room text not null references public.ti_rooms (code) on delete cascade,
  n int not null,
  psychic uuid not null,
  card_key text not null,
  left_label text not null,
  right_label text not null,
  clue text,
  phase text not null default 'clue' check (phase in ('clue', 'guessing', 'reveal')),
  skips int not null default 0,
  started_at timestamptz not null default now(),
  primary key (room, n)
);

create table public.ti_round_secrets (
  room text not null,
  n int not null,
  target numeric not null,
  primary key (room, n),
  foreign key (room, n) references public.ti_rounds (room, n) on delete cascade
);

create table public.ti_guesses (
  room text not null,
  n int not null,
  user_id uuid not null,
  value numeric not null check (value between 0 and 100),
  points numeric,
  locked_at timestamptz not null default now(),
  primary key (room, n, user_id),
  foreign key (room, n) references public.ti_rounds (room, n) on delete cascade
);

-- One row per room; every change bumps `tick` so phones know to refresh.
create table public.ti_room_ticks (
  room text primary key references public.ti_rooms (code) on delete cascade,
  tick bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.ti_cards enable row level security;
alter table public.ti_rooms enable row level security;
alter table public.ti_players enable row level security;
alter table public.ti_room_cards enable row level security;
alter table public.ti_rounds enable row level security;
alter table public.ti_round_secrets enable row level security;
alter table public.ti_guesses enable row level security;
alter table public.ti_room_ticks enable row level security;

-- Only the tick is readable directly (for Realtime), and only by the room's players.
create or replace function public.ti_is_room_member(p_room text)
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.ti_players where room = p_room and user_id = auth.uid()) $$;

create policy "members see their room's tick" on public.ti_room_ticks for select to authenticated
  using (public.ti_is_room_member(room));
grant select on public.ti_room_ticks to authenticated;

alter publication supabase_realtime add table public.ti_room_ticks;

-- ---------------------------------------------------------------- helpers

create or replace function public.ti_bump(p_room text)
returns void language sql security definer set search_path = ''
as $$
  update public.ti_room_ticks set tick = tick + 1, updated_at = now() where room = p_room;
  update public.ti_rooms set updated_at = now() where code = p_room;
$$;

create or replace function public.ti_active_players(p_room text)
returns setof public.ti_players language sql stable security definer set search_path = ''
as $$ select * from public.ti_players where room = p_room and left_at is null order by seat $$;

create or replace function public.ti_require_member(p_room text)
returns public.ti_rooms language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  select * into r from public.ti_rooms where code = upper(p_room) for update;
  if r.code is null then
    raise exception 'That room doesn''t exist (anymore)';
  end if;
  if not exists (select 1 from public.ti_players where room = r.code and user_id = auth.uid() and left_at is null) then
    raise exception 'You''re not in this room';
  end if;
  return r;
end
$$;

create or replace function public.ti_clean_name(p_name text)
returns text language sql immutable set search_path = ''
as $$ select left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 24) $$;

-- Points for one guess: 4 in the middle band, then 3, then 2.
create or replace function public.ti_points_for(p_guess numeric, p_target numeric, p_tol numeric)
returns numeric language sql immutable set search_path = ''
as $$
  select case
    when abs(p_guess - p_target) <= p_tol then 4
    when abs(p_guess - p_target) <= p_tol * 2 then 3
    when abs(p_guess - p_target) <= p_tol * 3 then 2
    else 0
  end
$$;

-- Deal a card the room hasn't seen yet (built-in or the room's own) and a new target.
create or replace function public.ti_deal(p_room text, p_n int)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c record;
begin
  select * into c from (
    select 'c' || id as key, left_label, right_label from public.ti_cards
    union all
    select 'r' || id, left_label, right_label from public.ti_room_cards where room = p_room
  ) all_cards
  where key not in (select card_key from public.ti_rounds where room = p_room and n <> p_n)
  order by random() limit 1;
  if c.key is null then
    -- Every card has been used: allow repeats.
    select 'c' || id as key, left_label, right_label into c from public.ti_cards order by random() limit 1;
  end if;
  update public.ti_rounds set card_key = c.key, left_label = c.left_label, right_label = c.right_label
    where room = p_room and n = p_n;
  insert into public.ti_round_secrets (room, n, target) values (p_room, p_n, round((3 + random() * 94)::numeric, 1))
    on conflict (room, n) do update set target = excluded.target;
end
$$;

create or replace function public.ti_start_round(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_n int;
  v_count int;
  v_psychic uuid;
begin
  select * into r from public.ti_rooms where code = p_room;
  v_n := r.round + 1;
  if v_n > r.rounds_total then
    update public.ti_rooms set status = 'finished' where code = p_room;
    return;
  end if;
  select count(*) into v_count from public.ti_active_players(p_room);
  select user_id into v_psychic from public.ti_active_players(p_room) offset ((v_n - 1) % greatest(v_count, 1)) limit 1;
  insert into public.ti_rounds (room, n, psychic, card_key, left_label, right_label)
    values (p_room, v_n, v_psychic, '', '', '');
  perform public.ti_deal(p_room, v_n);
  update public.ti_rooms set round = v_n where code = p_room;
end
$$;

-- Score the round: guessers by band, the psychic gets the guessers' average.
create or replace function public.ti_reveal(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_target numeric;
  v_avg numeric;
begin
  select * into r from public.ti_rooms where code = p_room;
  select * into rd from public.ti_rounds where room = p_room and n = r.round;
  if rd.phase <> 'guessing' then
    return;
  end if;
  select target into v_target from public.ti_round_secrets where room = p_room and n = rd.n;
  update public.ti_guesses g set points = public.ti_points_for(g.value, v_target, r.precision)
    where g.room = p_room and g.n = rd.n;
  update public.ti_players p set score = p.score + g.points
    from public.ti_guesses g where g.room = p_room and g.n = rd.n and p.room = p_room and p.user_id = g.user_id;
  select round(coalesce(round(avg(points) * 2) / 2, 0), 1) into v_avg from public.ti_guesses where room = p_room and n = rd.n;
  update public.ti_players set score = score + v_avg where room = p_room and user_id = rd.psychic;
  update public.ti_rounds set phase = 'reveal' where room = p_room and n = rd.n;
end
$$;

-- ---------------------------------------------------------------- actions

create or replace function public.ti_create_room(p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text;
  v_name text := public.ti_clean_name(p_name);
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  -- Tidy up rooms nobody has touched for two days.
  delete from public.ti_rooms where updated_at < now() - interval '2 days';
  loop
    v_code := (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 5));
    exit when not exists (select 1 from public.ti_rooms where code = v_code);
  end loop;
  insert into public.ti_rooms (code, host) values (v_code, auth.uid());
  insert into public.ti_players (room, user_id, name, seat) values (v_code, auth.uid(), v_name, 0);
  insert into public.ti_room_ticks (room) values (v_code);
  return v_code;
end
$$;

create or replace function public.ti_join_room(p_code text, p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_name text := public.ti_clean_name(p_name);
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  perform 1 from public.ti_rooms where code = v_code for update;
  if not found then
    raise exception 'No room with the code %', v_code;
  end if;
  if exists (select 1 from public.ti_active_players(v_code) where lower(name) = lower(v_name) and user_id <> auth.uid()) then
    raise exception 'Someone in this room is already called %', v_name;
  end if;
  if exists (select 1 from public.ti_players where room = v_code and user_id = auth.uid()) then
    update public.ti_players set name = v_name, left_at = null, last_seen = now() where room = v_code and user_id = auth.uid();
  else
    if (select count(*) from public.ti_active_players(v_code)) >= 12 then
      raise exception 'This room is full (12 players)';
    end if;
    insert into public.ti_players (room, user_id, name, seat)
      values (v_code, auth.uid(), v_name, coalesce((select max(seat) + 1 from public.ti_players where room = v_code), 0));
  end if;
  perform public.ti_bump(v_code);
  return v_code;
end
$$;

create or replace function public.ti_leave_room(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_next uuid;
begin
  r := public.ti_require_member(p_code);
  update public.ti_players set left_at = now() where room = r.code and user_id = auth.uid();
  if r.host = auth.uid() then
    select user_id into v_next from public.ti_active_players(r.code) limit 1;
    if v_next is null then
      delete from public.ti_rooms where code = r.code;
      return;
    end if;
    update public.ti_rooms set host = v_next where code = r.code;
  end if;
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_update_settings(p_code text, p_rounds_per_player int, p_precision int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can change the settings';
  end if;
  if r.status <> 'lobby' then
    raise exception 'The game has already started';
  end if;
  update public.ti_rooms set rounds_per_player = p_rounds_per_player, precision = p_precision where code = r.code;
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_add_card(p_code text, p_left text, p_right text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if coalesce(trim(p_left), '') = '' or coalesce(trim(p_right), '') = '' then
    raise exception 'Fill in both ends of the scale';
  end if;
  if (select count(*) from public.ti_room_cards where room = r.code) >= 60 then
    raise exception 'That''s plenty of custom scales for one room';
  end if;
  insert into public.ti_room_cards (room, left_label, right_label, added_by) values (r.code, left(trim(p_left), 40), left(trim(p_right), 40), auth.uid());
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_remove_card(p_code text, p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  delete from public.ti_room_cards where room = r.code and id = p_id and (added_by = auth.uid() or r.host = auth.uid());
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_start_game(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_count int;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can start the game';
  end if;
  if r.status = 'playing' then
    return;
  end if;
  select count(*) into v_count from public.ti_active_players(r.code);
  if v_count < 2 then
    raise exception 'You need at least 2 players';
  end if;
  delete from public.ti_rounds where room = r.code;
  update public.ti_players set score = 0 where room = r.code;
  update public.ti_rooms set status = 'playing', round = 0, rounds_total = v_count * r.rounds_per_player where code = r.code;
  perform public.ti_start_round(r.code);
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_skip_card(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if rd.psychic <> auth.uid() or rd.phase <> 'clue' then
    raise exception 'Only the psychic can draw another card, before giving a clue';
  end if;
  if rd.skips >= 3 then
    raise exception 'No more redraws this round';
  end if;
  update public.ti_rounds set skips = skips + 1 where room = r.code and n = rd.n;
  perform public.ti_deal(r.code, rd.n);
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_give_clue(p_code text, p_clue text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if rd.psychic <> auth.uid() or rd.phase <> 'clue' then
    raise exception 'It''s not your turn to give a clue';
  end if;
  if v_clue = '' then
    raise exception 'Type a clue';
  end if;
  update public.ti_rounds set clue = v_clue, phase = 'guessing' where room = r.code and n = rd.n;
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_lock_guess(p_code text, p_value numeric)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if r.status <> 'playing' or rd.phase <> 'guessing' then
    raise exception 'Not the time to guess';
  end if;
  if rd.psychic = auth.uid() then
    raise exception 'The psychic doesn''t guess';
  end if;
  if p_value is null then
    raise exception 'Move the needle first';
  end if;
  insert into public.ti_guesses (room, n, user_id, value) values (r.code, rd.n, auth.uid(), greatest(0, least(100, p_value)))
    on conflict (room, n, user_id) do nothing;
  -- Everyone in? Reveal.
  if not exists (
    select 1 from public.ti_active_players(r.code) p
    where p.user_id <> rd.psychic
      and not exists (select 1 from public.ti_guesses g where g.room = r.code and g.n = rd.n and g.user_id = p.user_id)
  ) then
    perform public.ti_reveal(r.code);
  end if;
  perform public.ti_bump(r.code);
end
$$;

-- When someone is taking too long: the host or the psychic can reveal anyway.
create or replace function public.ti_force_reveal(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if auth.uid() not in (r.host, rd.psychic) then
    raise exception 'Only the host or the psychic can reveal early';
  end if;
  perform public.ti_reveal(r.code);
  perform public.ti_bump(r.code);
end
$$;

-- Psychic left or went quiet before giving a clue: the host can skip the round.
create or replace function public.ti_skip_round(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can skip a round';
  end if;
  update public.ti_rounds set phase = 'reveal' where room = r.code and n = r.round and phase = 'clue';
  perform public.ti_start_round(r.code);
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_next_round(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.status <> 'playing' or not exists (select 1 from public.ti_rounds where room = r.code and n = r.round and phase = 'reveal') then
    return;
  end if;
  perform public.ti_start_round(r.code);
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_play_again(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can start a new game';
  end if;
  delete from public.ti_rounds where room = r.code;
  update public.ti_players set score = 0 where room = r.code;
  update public.ti_rooms set status = 'lobby', round = 0, rounds_total = 0 where code = r.code;
  perform public.ti_bump(r.code);
end
$$;

create or replace function public.ti_heartbeat(p_code text)
returns void
language sql security definer set search_path = ''
as $$ update public.ti_players set last_seen = now() where room = upper(p_code) and user_id = auth.uid() $$;

-- ---------------------------------------------------------------- state

-- Everything a player may see right now (secrets filtered out).
create or replace function public.ti_get_room_state(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_me uuid := auth.uid();
  v_reveal boolean;
begin
  select * into r from public.ti_rooms where code = upper(trim(coalesce(p_code, '')));
  if r.code is null then
    return jsonb_build_object('missing', true);
  end if;
  if not exists (select 1 from public.ti_players where room = r.code and user_id = v_me and left_at is null) then
    return jsonb_build_object('code', r.code, 'joined', false, 'status', r.status);
  end if;
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  v_reveal := rd.phase = 'reveal';
  return jsonb_build_object(
    'code', r.code,
    'joined', true,
    'me', v_me,
    'host', r.host,
    'status', r.status,
    'round', r.round,
    'rounds_total', r.rounds_total,
    'rounds_per_player', r.rounds_per_player,
    'precision', r.precision,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.user_id, 'name', p.name, 'seat', p.seat, 'score', p.score,
                                          'online', p.last_seen > now() - interval '45 seconds') order by p.seat)
      from public.ti_active_players(r.code) p), '[]'::jsonb),
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'left', c.left_label, 'right', c.right_label, 'mine', c.added_by = v_me) order by c.id)
      from public.ti_room_cards c where c.room = r.code), '[]'::jsonb),
    'current', case when rd.room is null then null else jsonb_build_object(
      'n', rd.n,
      'psychic', rd.psychic,
      'left', rd.left_label,
      'right', rd.right_label,
      'clue', rd.clue,
      'phase', rd.phase,
      'skips', rd.skips,
      'target', case when v_reveal or rd.psychic = v_me then (select target from public.ti_round_secrets s where s.room = r.code and s.n = rd.n) end,
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', g.user_id,
          'value', case when v_reveal or g.user_id = v_me then g.value end,
          'points', case when v_reveal then g.points end))
        from public.ti_guesses g where g.room = r.code and g.n = rd.n), '[]'::jsonb)
    ) end
  );
end
$$;

-- ---------------------------------------------------------------- permissions

do $$
declare
  f text;
begin
  foreach f in array array[
    'ti_create_room(text)', 'ti_join_room(text, text)', 'ti_leave_room(text)', 'ti_update_settings(text, int, int)',
    'ti_add_card(text, text, text)', 'ti_remove_card(text, bigint)', 'ti_start_game(text)', 'ti_skip_card(text)',
    'ti_give_clue(text, text)', 'ti_lock_guess(text, numeric)', 'ti_force_reveal(text)', 'ti_skip_round(text)',
    'ti_next_round(text)', 'ti_play_again(text)', 'ti_heartbeat(text)', 'ti_get_room_state(text)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array[
    'ti_is_room_member(text)', 'ti_bump(text)', 'ti_active_players(text)', 'ti_require_member(text)', 'ti_deal(text, int)',
    'ti_start_round(text)', 'ti_reveal(text)', 'ti_points_for(numeric, numeric, numeric)', 'ti_clean_name(text)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end
$$;
-- is_room_member is used by the room_ticks policy, so authenticated users need it.
grant execute on function public.ti_is_room_member(text) to authenticated;

-- The built-in deck of scales (rooms can add their own too).
insert into public.ti_cards (left_label, right_label) values
  ('Cold', 'Hot'),
  ('Quiet', 'Loud'),
  ('Cheap', 'Expensive'),
  ('Boring', 'Exciting'),
  ('Naughty', 'Nice'),
  ('Healthy', 'Unhealthy'),
  ('Overrated', 'Underrated'),
  ('Bad gift', 'Great gift'),
  ('Easy to wrap', 'Impossible to wrap'),
  ('Cozy', 'Scary'),
  ('Calm', 'Chaotic'),
  ('Childish', 'Grown-up'),
  ('Ugly', 'Beautiful'),
  ('Useless', 'Essential'),
  ('Sad song', 'Happy song'),
  ('Bad film', 'Great film'),
  ('Weird food', 'Normal food'),
  ('Tiny', 'Huge'),
  ('Slow', 'Fast'),
  ('Old-fashioned', 'Trendy'),
  ('Easy', 'Hard'),
  ('Dangerous', 'Safe'),
  ('Rare', 'Common'),
  ('Smells bad', 'Smells great'),
  ('Lazy activity', 'Exhausting activity'),
  ('Unromantic', 'Romantic'),
  ('Morning thing', 'Night thing'),
  ('Indoor', 'Outdoor'),
  ('Forgettable', 'Unforgettable'),
  ('Soft', 'Hard'),
  ('Mild', 'Spicy'),
  ('Sweet', 'Savoury'),
  ('Relaxing', 'Stressful'),
  ('Bad habit', 'Good habit'),
  ('Villain', 'Hero'),
  ('Introvert activity', 'Extrovert activity'),
  ('Cheap date', 'Fancy date'),
  ('Summer', 'Winter'),
  ('Underdressed', 'Overdressed'),
  ('Normal pet', 'Unusual pet'),
  ('Bad superpower', 'Great superpower'),
  ('Simple', 'Complicated'),
  ('Worst Christmas song', 'Best Christmas song'),
  ('Worst holiday food', 'Best holiday food'),
  ('Low effort gift', 'High effort gift'),
  ('Bad idea at a party', 'Great idea at a party'),
  ('Fragile', 'Indestructible'),
  ('Dirty', 'Clean'),
  ('Unknown', 'Famous'),
  ('Fiction', 'Real'),
  ('Silent', 'Noisy hobby'),
  ('Mundane', 'Magical'),
  ('Rude', 'Polite'),
  ('Short-lived', 'Lasts forever'),
  ('Cringe', 'Cool'),
  ('Hated chore', 'Loved chore'),
  ('Cat person thing', 'Dog person thing'),
  ('Waste of money', 'Worth every penny'),
  ('Tastes bad', 'Tastes great'),
  ('Ordinary', 'Luxurious'),
  ('Easy to learn', 'Hard to learn'),
  ('Sounds made up', 'Sounds real'),
  ('Peaceful', 'Violent'),
  ('Beginner', 'Expert'),
  ('Underground', 'Mainstream'),
  ('Plain', 'Fancy'),
  ('Wet', 'Dry'),
  ('Harmless', 'Deadly'),
  ('Square', 'Round'),
  ('Dark', 'Bright'),
  ('Sour', 'Sweet'),
  ('Scary film', 'Feel-good film'),
  ('Lame party', 'Legendary party'),
  ('Basic', 'Exotic'),
  ('Mild weather', 'Extreme weather'),
  ('Light', 'Heavy'),
  ('Bad at hiding', 'Good at hiding'),
  ('Low stakes', 'High stakes'),
  ('Unpopular opinion', 'Popular opinion'),
  ('Needs no skill', 'Needs lots of skill'),
  ('Smooth', 'Rough'),
  ('Bad first date', 'Great first date'),
  ('Grandma would hate it', 'Grandma would love it'),
  ('Cheap thrill', 'Once in a lifetime'),
  ('Everyday item', 'Collector''s item'),
  ('Socially awkward', 'Smooth talker'),
  ('Background character', 'Main character'),
  ('Normal Tuesday', 'Best day ever'),
  ('Bad smell', 'Good smell'),
  ('Junk food', 'Gourmet food'),
  ('Sleepy', 'Energetic'),
  ('Ancient', 'Futuristic'),
  ('Unhelpful', 'Helpful'),
  ('Tacky decoration', 'Classy decoration'),
  ('Overcooked', 'Undercooked'),
  ('Gentle', 'Fierce'),
  ('Snack', 'Meal'),
  ('Short trip', 'Long trip'),
  ('Unlucky', 'Lucky'),
  ('Mess', 'Masterpiece');

-- Fixes found while testing: rejoining can't take someone else's name, the
-- psychic's points are rounded to one decimal, and an empty guess is refused.

create or replace function public.ti_join_room(p_code text, p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_name text := public.ti_clean_name(p_name);
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  perform 1 from public.ti_rooms where code = v_code for update;
  if not found then
    raise exception 'No room with the code %', v_code;
  end if;
  if exists (select 1 from public.ti_active_players(v_code) where lower(name) = lower(v_name) and user_id <> auth.uid()) then
    raise exception 'Someone in this room is already called %', v_name;
  end if;
  if exists (select 1 from public.ti_players where room = v_code and user_id = auth.uid()) then
    update public.ti_players set name = v_name, left_at = null, last_seen = now() where room = v_code and user_id = auth.uid();
  else
    if (select count(*) from public.ti_active_players(v_code)) >= 12 then
      raise exception 'This room is full (12 players)';
    end if;
    insert into public.ti_players (room, user_id, name, seat)
      values (v_code, auth.uid(), v_name, coalesce((select max(seat) + 1 from public.ti_players where room = v_code), 0));
  end if;
  perform public.ti_bump(v_code);
  return v_code;
end
$$;

create or replace function public.ti_reveal(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_target numeric;
  v_avg numeric;
begin
  select * into r from public.ti_rooms where code = p_room;
  select * into rd from public.ti_rounds where room = p_room and n = r.round;
  if rd.phase <> 'guessing' then
    return;
  end if;
  select target into v_target from public.ti_round_secrets where room = p_room and n = rd.n;
  update public.ti_guesses g set points = public.ti_points_for(g.value, v_target, r.precision)
    where g.room = p_room and g.n = rd.n;
  update public.ti_players p set score = p.score + g.points
    from public.ti_guesses g where g.room = p_room and g.n = rd.n and p.room = p_room and p.user_id = g.user_id;
  select round(coalesce(round(avg(points) * 2) / 2, 0), 1) into v_avg from public.ti_guesses where room = p_room and n = rd.n;
  update public.ti_players set score = score + v_avg where room = p_room and user_id = rd.psychic;
  update public.ti_rounds set phase = 'reveal' where room = p_room and n = rd.n;
end
$$;

create or replace function public.ti_lock_guess(p_code text, p_value numeric)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if r.status <> 'playing' or rd.phase <> 'guessing' then
    raise exception 'Not the time to guess';
  end if;
  if rd.psychic = auth.uid() then
    raise exception 'The psychic doesn''t guess';
  end if;
  if p_value is null then
    raise exception 'Move the needle first';
  end if;
  insert into public.ti_guesses (room, n, user_id, value) values (r.code, rd.n, auth.uid(), greatest(0, least(100, p_value)))
    on conflict (room, n, user_id) do nothing;
  -- Everyone in? Reveal.
  if not exists (
    select 1 from public.ti_active_players(r.code) p
    where p.user_id <> rd.psychic
      and not exists (select 1 from public.ti_guesses g where g.room = r.code and g.n = rd.n and g.user_id = p.user_id)
  ) then
    perform public.ti_reveal(r.code);
  end if;
  perform public.ti_bump(r.code);
end
$$;

-- The psychic sets up each round like the advent calendar's editor: both ends
-- of the scale, the clue, the secret spot (dragged on the dial) and the
-- precision for that round. The dealt card and random spot are just a start.

alter table public.ti_rounds add column if not exists precision int check (precision in (4, 7, 10));

create or replace function public.ti_set_round(p_code text, p_left text, p_right text, p_clue text, p_target numeric, p_precision int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_left text := left(regexp_replace(trim(coalesce(p_left, '')), '\s+', ' ', 'g'), 40);
  v_right text := left(regexp_replace(trim(coalesce(p_right, '')), '\s+', ' ', 'g'), 40);
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  r := public.ti_require_member(p_code);
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  if rd.psychic <> auth.uid() or rd.phase <> 'clue' then
    raise exception 'It''s not your turn to set up the round';
  end if;
  if v_left = '' or v_right = '' then
    raise exception 'Write both ends of the scale';
  end if;
  if v_clue = '' then
    raise exception 'Write the clue';
  end if;
  if p_target is null or p_target < 0 or p_target > 100 then
    raise exception 'Set the secret spot on the dial';
  end if;
  if p_precision not in (4, 7, 10) then
    raise exception 'Pick a precision';
  end if;
  update public.ti_rounds
    set left_label = v_left, right_label = v_right, clue = v_clue, precision = p_precision, phase = 'guessing'
    where room = r.code and n = rd.n;
  insert into public.ti_round_secrets (room, n, target) values (r.code, rd.n, round(p_target, 1))
    on conflict (room, n) do update set target = excluded.target;
  perform public.ti_bump(r.code);
end
$$;
revoke execute on function public.ti_set_round(text, text, text, text, numeric, int) from public, anon;
grant execute on function public.ti_set_round(text, text, text, text, numeric, int) to authenticated;

-- Scoring uses the round's own precision (falls back to the room's).
create or replace function public.ti_reveal(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_target numeric;
  v_tol numeric;
  v_avg numeric;
begin
  select * into r from public.ti_rooms where code = p_room;
  select * into rd from public.ti_rounds where room = p_room and n = r.round;
  if rd.phase <> 'guessing' then
    return;
  end if;
  v_tol := coalesce(rd.precision, r.precision);
  select target into v_target from public.ti_round_secrets where room = p_room and n = rd.n;
  update public.ti_guesses g set points = public.ti_points_for(g.value, v_target, v_tol)
    where g.room = p_room and g.n = rd.n;
  update public.ti_players p set score = p.score + g.points
    from public.ti_guesses g where g.room = p_room and g.n = rd.n and p.room = p_room and p.user_id = g.user_id;
  select round(coalesce(round(avg(points) * 2) / 2, 0), 1) into v_avg from public.ti_guesses where room = p_room and n = rd.n;
  update public.ti_players set score = score + v_avg where room = p_room and user_id = rd.psychic;
  update public.ti_rounds set phase = 'reveal' where room = p_room and n = rd.n;
end
$$;
revoke execute on function public.ti_reveal(text) from public, anon, authenticated;

-- State includes the round's precision.
create or replace function public.ti_get_room_state(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
  v_me uuid := auth.uid();
  v_reveal boolean;
begin
  select * into r from public.ti_rooms where code = upper(trim(coalesce(p_code, '')));
  if r.code is null then
    return jsonb_build_object('missing', true);
  end if;
  if not exists (select 1 from public.ti_players where room = r.code and user_id = v_me and left_at is null) then
    return jsonb_build_object('code', r.code, 'joined', false, 'status', r.status);
  end if;
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  v_reveal := rd.phase = 'reveal';
  return jsonb_build_object(
    'code', r.code,
    'joined', true,
    'me', v_me,
    'host', r.host,
    'status', r.status,
    'round', r.round,
    'rounds_total', r.rounds_total,
    'rounds_per_player', r.rounds_per_player,
    'precision', r.precision,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.user_id, 'name', p.name, 'seat', p.seat, 'score', p.score,
                                          'online', p.last_seen > now() - interval '45 seconds') order by p.seat)
      from public.ti_active_players(r.code) p), '[]'::jsonb),
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'left', c.left_label, 'right', c.right_label, 'mine', c.added_by = v_me) order by c.id)
      from public.ti_room_cards c where c.room = r.code), '[]'::jsonb),
    'current', case when rd.room is null then null else jsonb_build_object(
      'n', rd.n,
      'psychic', rd.psychic,
      'left', rd.left_label,
      'right', rd.right_label,
      'clue', rd.clue,
      'phase', rd.phase,
      'skips', rd.skips,
      'precision', coalesce(rd.precision, r.precision),
      'target', case when v_reveal or rd.psychic = v_me then (select target from public.ti_round_secrets s where s.room = r.code and s.n = rd.n) end,
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', g.user_id,
          'value', case when v_reveal or g.user_id = v_me then g.value end,
          'points', case when v_reveal then g.points end))
        from public.ti_guesses g where g.room = r.code and g.n = rd.n), '[]'::jsonb)
    ) end
  );
end
$$;

