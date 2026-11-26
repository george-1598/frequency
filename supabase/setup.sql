-- Frequency: full database setup (run once in the Supabase SQL editor).
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

-- Players can join at any time; joining mid-game adds their creator turns.
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
    -- Joining a game in progress: add their turns as creator at the end.
    update public.ti_rooms set rounds_total = rounds_total + rounds_per_player
      where code = v_code and status = 'playing';
  end if;
  perform public.ti_bump(v_code);
  return v_code;
end
$$;

-- Simpler flow: creating a room starts the game straight away (with a room name,
-- random if left empty, and the rounds each player creates). Anyone can add one
-- more round for everyone during the final rotation; the host can end early;
-- "play again" restarts directly.

alter table public.ti_rooms add column if not exists name text check (length(name) <= 40);

create or replace function public.ti_random_room_name()
returns text language sql volatile set search_path = ''
as $$
  select (array['Cozy','Lucky','Sunny','Snowy','Golden','Velvet','Midnight','Merry','Jolly','Sparkly','Silver','Crimson','Happy','Cosmic','Tiny','Mighty','Secret','Dreamy','Frosty','Groovy'])[1 + floor(random() * 20)::int]
    || ' ' ||
    (array['Comet','Otter','Lantern','Pancake','Penguin','Rocket','Waffle','Panda','Cactus','Meteor','Teapot','Fox','Disco','Muffin','Walrus','Cupcake','Dragon','Pixel','Radio','Moose'])[1 + floor(random() * 20)::int]
$$;

drop function if exists public.ti_create_room(text);
create or replace function public.ti_create_room(p_name text, p_room_name text default null, p_rounds_per_player int default 2)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text;
  v_name text := public.ti_clean_name(p_name);
  v_room_name text := left(regexp_replace(trim(coalesce(p_room_name, '')), '\s+', ' ', 'g'), 40);
  v_rounds int := greatest(1, least(5, coalesce(p_rounds_per_player, 2)));
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  if v_room_name = '' then
    v_room_name := public.ti_random_room_name();
  end if;
  delete from public.ti_rooms where updated_at < now() - interval '2 days';
  loop
    v_code := (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 5));
    exit when not exists (select 1 from public.ti_rooms where code = v_code);
  end loop;
  insert into public.ti_rooms (code, host, name, rounds_per_player, status, round, rounds_total)
    values (v_code, auth.uid(), v_room_name, v_rounds, 'playing', 0, v_rounds);
  insert into public.ti_players (room, user_id, name, seat) values (v_code, auth.uid(), v_name, 0);
  insert into public.ti_room_ticks (room) values (v_code);
  perform public.ti_start_round(v_code);
  return v_code;
end
$$;

-- (Older rooms still in the lobby can start with just one player now.)
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
  delete from public.ti_rounds where room = r.code;
  update public.ti_players set score = 0 where room = r.code;
  update public.ti_rooms set status = 'playing', round = 0, rounds_total = v_count * r.rounds_per_player where code = r.code;
  perform public.ti_start_round(r.code);
  perform public.ti_bump(r.code);
end
$$;

-- During the final rotation, anyone can give every player one more turn as creator.
create or replace function public.ti_add_round(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_count int;
begin
  r := public.ti_require_member(p_code);
  if r.status <> 'playing' then
    raise exception 'The game isn''t running';
  end if;
  select count(*) into v_count from public.ti_active_players(r.code);
  if r.round <= r.rounds_total - v_count then
    raise exception 'There are still rounds left for everyone';
  end if;
  if r.rounds_total + v_count > 120 then
    raise exception 'That''s a lot of rounds already!';
  end if;
  update public.ti_rooms set rounds_total = rounds_total + v_count where code = r.code;
  perform public.ti_bump(r.code);
end
$$;

-- The host can end the game early (straight to the final scores).
create or replace function public.ti_end_game(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can end the game';
  end if;
  update public.ti_rooms set status = 'finished' where code = r.code;
  perform public.ti_bump(r.code);
end
$$;

-- Play again: same room and settings, straight into round 1.
create or replace function public.ti_play_again(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_count int;
begin
  r := public.ti_require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can start a new game';
  end if;
  select count(*) into v_count from public.ti_active_players(r.code);
  delete from public.ti_rounds where room = r.code;
  update public.ti_players set score = 0 where room = r.code;
  update public.ti_rooms set status = 'playing', round = 0, rounds_total = v_count * r.rounds_per_player where code = r.code;
  perform public.ti_start_round(r.code);
  perform public.ti_bump(r.code);
end
$$;

-- State includes the room's name.
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
    'name', r.name,
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

do $$
declare
  f text;
begin
  foreach f in array array['ti_create_room(text, text, int)', 'ti_start_game(text)', 'ti_add_round(text)', 'ti_end_game(text)', 'ti_play_again(text)', 'ti_get_room_state(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end
$$;
revoke execute on function public.ti_random_room_name() from public, anon, authenticated;

-- Precision options: generous 7, normal 4, tight 3 (tight is the default).
-- 10 stays allowed so rounds from older games still read correctly.
alter table public.ti_rooms drop constraint if exists ti_rooms_precision_check;
alter table public.ti_rooms add constraint ti_rooms_precision_check check (precision in (3, 4, 7, 10));
alter table public.ti_rooms alter column precision set default 3;
alter table public.ti_rounds drop constraint if exists ti_rounds_precision_check;
alter table public.ti_rounds add constraint ti_rounds_precision_check check (precision in (3, 4, 7, 10));

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
  if p_precision not in (3, 4, 7) then
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

-- More scales for the deck: lots about relationships, plus general fun ones.
insert into public.ti_cards (left_label, right_label) values
  ('Not romantic', 'Very romantic'),
  ('Red flag', 'Green flag'),
  ('Dealbreaker', 'Dream partner'),
  ('Low effort', 'High effort'),
  ('Awkward first date', 'Perfect first date'),
  ('Too soon', 'Perfect timing'),
  ('Cringey pet name', 'Cute pet name'),
  ('Unforgivable', 'Easily forgiven'),
  ('Couple goals', 'Couple fail'),
  ('Only friends do it', 'Only couples do it'),
  ('Boring night in', 'Perfect night in'),
  ('Keep it private', 'Share with everyone'),
  ('Totally chill', 'Very jealous'),
  ('Terrible gift for a partner', 'Perfect gift for a partner'),
  ('Rarely', 'Constantly'),
  ('Easy to agree on', 'Impossible to agree on'),
  ('Unattractive habit', 'Attractive habit'),
  ('Clingy', 'Independent'),
  ('Great first-date topic', 'Never on a first date'),
  ('Small gesture', 'Grand gesture'),
  ('Starts a fight', 'Ends a fight'),
  ('Sweet', 'Way over the top'),
  ('Boring couple activity', 'Fun couple activity'),
  ('Minor annoyance', 'Relationship ender'),
  ('Easy to say', 'Hard to say'),
  ('Just friends', 'Soulmates'),
  ('Hates surprises', 'Loves surprises'),
  ('Unromantic place', 'Romantic place'),
  ('Bad advice', 'Great advice'),
  ('Lazy Sunday', 'Adventurous Sunday'),
  ('Least important in a partner', 'Most important in a partner'),
  ('Petty argument', 'Serious argument'),
  ('Cheesy line', 'Smooth line'),
  ('Happy to share', 'Never sharing'),
  ('Weird thing couples do', 'Normal thing couples do'),
  ('Always forgets', 'Never forgets'),
  ('Wouldn’t do it for love', 'Would do it for love'),
  ('Sweet', 'Too much'),
  ('Fleeting crush', 'True love'),
  ('Embarrassing', 'Adorable'),
  ('Least romantic month', 'Most romantic month'),
  ('Doesn’t matter', 'Matters a lot'),
  ('Terrible cook', 'Master chef'),
  ('Bad listener', 'Great listener'),
  ('Low-key', 'Extra'),
  ('Turn-off', 'Charming'),
  ('Ruins a friendship', 'Builds a friendship'),
  ('Easy to keep', 'Impossible to keep'),
  ('No big deal', 'Huge deal'),
  ('Grumpy', 'Cuddly'),
  ('Bad at texting', 'Great at texting'),
  ('Total stranger', 'Basically family'),
  ('Annoying', 'Endearing'),
  ('Wild night out', 'Cosy evening'),
  ('Boring date idea', 'Creative date idea'),
  ('Never', 'Every single day'),
  ('Bad relationship advice', 'Good relationship advice'),
  ('Forgettable moment', 'Unforgettable moment'),
  ('Easy chore to share', 'Chore worth fighting over'),
  ('White lie', 'Big lie'),
  ('Needs no reason', 'Needs a big reason'),
  ('Not cute', 'Very cute'),
  ('Bad for a relationship', 'Good for a relationship'),
  ('Reply instantly', 'Leave on read'),
  ('Relaxing trip together', 'Stressful trip together'),
  ('Every day', 'Special occasions only'),
  ('Anti-romance film', 'Romance film'),
  ('Spontaneous', 'Carefully planned'),
  ('Totally private', 'Public display of affection'),
  ('Easy to impress', 'Hard to impress'),
  ('Small talk', 'Deep talk'),
  ('Cute couple habit', 'Annoying couple habit'),
  ('Calm animal', 'Chaotic animal'),
  ('Silly', 'Serious'),
  ('Wallflower', 'Life of the party'),
  ('Underrated snack', 'Overrated snack'),
  ('Worst season', 'Best season'),
  ('Cheap holiday', 'Dream holiday'),
  ('Bad pet name', 'Great pet name'),
  ('Overpriced', 'Bargain'),
  ('Easy to draw', 'Hard to draw'),
  ('Hidden talent', 'Obvious talent'),
  ('Guilty pleasure', 'Proud pleasure'),
  ('Sounds tasty', 'Sounds disgusting'),
  ('Kids love it', 'Adults love it'),
  ('Pointless invention', 'Life-changing invention'),
  ('Normal Saturday', 'Perfect Saturday'),
  ('Weak', 'Strong'),
  ('Homebody', 'Globetrotter'),
  ('Calm job', 'Stressful job'),
  ('Boring job', 'Dream job'),
  ('Useless skill', 'Useful skill'),
  ('Cheap hobby', 'Expensive hobby'),
  ('Boring to watch', 'Thrilling to watch'),
  ('Morning drink', 'Evening drink'),
  ('Soft-spoken', 'Very loud'),
  ('Not scary', 'Terrifying'),
  ('Cute animal', 'Ugly animal'),
  ('Ordinary sandwich', 'Legendary sandwich'),
  ('Easy to pronounce', 'Hard to pronounce'),
  ('Myth', 'Fact'),
  ('Only tasty at 3 am', 'Tasty any time'),
  ('Calming sound', 'Annoying sound'),
  ('Classy drink', 'Trashy drink'),
  ('Useless app', 'Essential app'),
  ('Normal fear', 'Weird fear'),
  ('Too short', 'Too long'),
  ('Bad gift for a boss', 'Good gift for a boss'),
  ('Overrated city', 'Underrated city'),
  ('Weird collection', 'Normal collection'),
  ('Timeless', 'Dated'),
  ('Annoying song', 'Great song'),
  ('Kid-friendly', 'Adults only'),
  ('Bad picnic weather', 'Perfect picnic weather'),
  ('Smells like childhood', 'Smells like adulthood'),
  ('Rarely used', 'Used every day'),
  ('Boring holiday', 'Exciting holiday'),
  ('Easy to forget', 'Hard to forget'),
  ('Good in theory', 'Good in practice'),
  ('Clumsy', 'Athletic'),
  ('Underpaid', 'Overpaid'),
  ('Tasty combo', 'Weird combo'),
  ('Chill game', 'Rage game'),
  ('Normal breakfast', 'Weird breakfast'),
  ('Bad life advice', 'Great life advice'),
  ('Mild inconvenience', 'Total disaster'),
  ('Lazy weekend', 'Productive weekend'),
  ('Old person thing', 'Young person thing'),
  ('Useless in a zombie apocalypse', 'Essential in a zombie apocalypse'),
  ('Boring superpower', 'Amazing superpower'),
  ('Easy dance', 'Hard dance'),
  ('Cheap date snack', 'Fancy date snack'),
  ('Never regift', 'Perfect to regift'),
  ('Better hot', 'Better cold'),
  ('Nobody likes it', 'Everybody likes it'),
  ('Pointless on holiday', 'Essential on holiday'),
  ('Quick fix', 'Long-term solution'),
  ('Polite on a train', 'Rude on a train'),
  ('Not worth the hype', 'Worth the hype'),
  ('Ancient history', 'Feels like yesterday'),
  ('Plain', 'Over the top'),
  ('Bad to binge', 'Perfect to binge');

-- The host can choose the room code (4–8 letters/digits) instead of a room name;
-- left empty, a random 5-character code is generated.

drop function if exists public.ti_create_room(text, text, int);
create or replace function public.ti_create_room(p_name text, p_code text default null, p_rounds_per_player int default 3)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s+', '', 'g'));
  v_name text := public.ti_clean_name(p_name);
  v_rounds int := greatest(1, least(5, coalesce(p_rounds_per_player, 3)));
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  delete from public.ti_rooms where updated_at < now() - interval '2 days';
  if v_code <> '' then
    if v_code !~ '^[A-Z0-9]{4,8}$' then
      raise exception 'The room code should be 4 to 8 letters or numbers';
    end if;
    if exists (select 1 from public.ti_rooms where code = v_code) then
      raise exception 'The code % is already in use. Pick another one, or leave it empty for a random code.', v_code;
    end if;
  else
    loop
      v_code := (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 5));
      exit when not exists (select 1 from public.ti_rooms where code = v_code);
    end loop;
  end if;
  insert into public.ti_rooms (code, host, rounds_per_player, status, round, rounds_total)
    values (v_code, auth.uid(), v_rounds, 'playing', 0, v_rounds);
  insert into public.ti_players (room, user_id, name, seat) values (v_code, auth.uid(), v_name, 0);
  insert into public.ti_room_ticks (room) values (v_code);
  perform public.ti_start_round(v_code);
  return v_code;
end
$$;
revoke execute on function public.ti_create_room(text, text, int) from public, anon;
grant execute on function public.ti_create_room(text, text, int) to authenticated;

-- Round-by-round recap for the results screen: every revealed round with its
-- scale, clue, target and everyone's guesses. Only once the game is finished.
create or replace function public.ti_room_recap(p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
begin
  r := public.ti_require_member(p_code);
  if r.status <> 'finished' then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'n', rd.n,
      'psychic', rd.psychic,
      'psychic_name', (select p.name from public.ti_players p where p.room = r.code and p.user_id = rd.psychic),
      'left', rd.left_label,
      'right', rd.right_label,
      'clue', rd.clue,
      'precision', coalesce(rd.precision, r.precision),
      'target', s.target,
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', g.user_id, 'name', p.name, 'seat', p.seat, 'value', g.value, 'points', g.points)
                         order by g.points desc nulls last, p.seat)
        from public.ti_guesses g join public.ti_players p on p.room = g.room and p.user_id = g.user_id
        where g.room = r.code and g.n = rd.n), '[]'::jsonb)
    ) order by rd.n)
    from public.ti_rounds rd
    join public.ti_round_secrets s on s.room = rd.room and s.n = rd.n
    where rd.room = r.code and rd.phase = 'reveal'), '[]'::jsonb);
end
$$;
revoke execute on function public.ti_room_recap(text) from public, anon;
grant execute on function public.ti_room_recap(text) to authenticated;

-- Admin page: unlocked with a password (the guest account that unlocks it
-- becomes an admin). The password hash is set separately, never committed:
--   update public.ti_admin_config set password_hash = extensions.crypt('…', extensions.gen_salt('bf'));

create table if not exists public.ti_admin_config (
  id int primary key default 1 check (id = 1),
  password_hash text
);
insert into public.ti_admin_config (id) values (1) on conflict do nothing;
create table if not exists public.ti_admins (user_id uuid primary key, added_at timestamptz not null default now());
create table if not exists public.ti_admin_attempts (at timestamptz not null default now());
alter table public.ti_admin_config enable row level security;
alter table public.ti_admins enable row level security;
alter table public.ti_admin_attempts enable row level security;

create or replace function public.ti_is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.ti_admins where user_id = auth.uid()) $$;

create or replace function public.ti_require_admin()
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.ti_is_admin() then
    raise exception 'Admins only';
  end if;
end
$$;

create or replace function public.ti_admin_unlock(p_password text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text := (select password_hash from public.ti_admin_config where id = 1);
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  delete from public.ti_admin_attempts where at < now() - interval '1 day';
  if (select count(*) from public.ti_admin_attempts where at > now() - interval '15 minutes') >= 10 then
    raise exception 'Too many wrong tries. Wait 15 minutes and try again.';
  end if;
  if v_hash is null or coalesce(p_password, '') = '' or extensions.crypt(p_password, v_hash) <> v_hash then
    insert into public.ti_admin_attempts default values;
    return false;
  end if;
  insert into public.ti_admins (user_id) values (auth.uid()) on conflict do nothing;
  return true;
end
$$;

create or replace function public.ti_admin_lock()
returns void language sql security definer set search_path = ''
as $$ delete from public.ti_admins where user_id = auth.uid() $$;

create or replace function public.ti_admin_set_password(p_old text, p_new text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text := (select password_hash from public.ti_admin_config where id = 1);
begin
  perform public.ti_require_admin();
  if extensions.crypt(coalesce(p_old, ''), v_hash) <> v_hash then
    raise exception 'The current password is wrong';
  end if;
  if length(coalesce(p_new, '')) < 8 then
    raise exception 'The new password needs at least 8 characters';
  end if;
  update public.ti_admin_config set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = 1;
  -- Everyone else has to unlock again with the new password.
  delete from public.ti_admins where user_id <> auth.uid();
end
$$;

-- Every room with its players, newest activity first, plus a few totals.
create or replace function public.ti_admin_overview()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_rooms jsonb;
begin
  perform public.ti_require_admin();
  select coalesce(jsonb_agg(x.j order by x.last_active desc), '[]'::jsonb) into v_rooms
  from (
    select greatest(r.updated_at, (select max(p.last_seen) from public.ti_players p where p.room = r.code)) last_active,
      jsonb_build_object(
        'code', r.code,
        'status', r.status,
        'round', r.round,
        'rounds_total', r.rounds_total,
        'created_at', r.created_at,
        'last_active', greatest(r.updated_at, (select max(p.last_seen) from public.ti_players p where p.room = r.code)),
        'phase', (select rd.phase from public.ti_rounds rd where rd.room = r.code and rd.n = r.round),
        'clue', (select rd.clue from public.ti_rounds rd where rd.room = r.code and rd.n = r.round),
        'creator', (select rd.psychic from public.ti_rounds rd where rd.room = r.code and rd.n = r.round),
        'host', r.host,
        'players', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.user_id, 'name', p.name, 'seat', p.seat, 'score', p.score,
            'online', p.left_at is null and p.last_seen > now() - interval '45 seconds',
            'left', p.left_at is not null, 'last_seen', p.last_seen) order by p.left_at nulls first, p.seat)
          from public.ti_players p where p.room = r.code), '[]'::jsonb)
      ) j
    from public.ti_rooms r
  ) x;
  return jsonb_build_object(
    'rooms', v_rooms,
    'online', (select count(distinct user_id) from public.ti_players where left_at is null and last_seen > now() - interval '45 seconds'),
    'active_rooms', (select count(*) from public.ti_rooms r where exists (
       select 1 from public.ti_players p where p.room = r.code and p.left_at is null and p.last_seen > now() - interval '10 minutes')),
    'rooms_today', (select count(*) from public.ti_rooms where created_at > now() - interval '24 hours')
  );
end
$$;

create or replace function public.ti_admin_delete_room(p_code text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  delete from public.ti_rooms where code = upper(p_code);
end
$$;

create or replace function public.ti_admin_end_game(p_code text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  update public.ti_rooms set status = 'finished' where code = upper(p_code) and status <> 'finished';
  perform public.ti_bump(upper(p_code));
end
$$;

-- Remove a player from a room (like them pressing Leave).
create or replace function public.ti_admin_kick(p_code text, p_user uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  v_next uuid;
begin
  perform public.ti_require_admin();
  select * into r from public.ti_rooms where code = upper(p_code);
  if r.code is null then
    return;
  end if;
  update public.ti_players set left_at = now() where room = r.code and user_id = p_user and left_at is null;
  select user_id into v_next from public.ti_active_players(r.code) limit 1;
  if v_next is null then
    delete from public.ti_rooms where code = r.code;
    return;
  end if;
  if r.host = p_user then
    update public.ti_rooms set host = v_next where code = r.code;
  end if;
  perform public.ti_bump(r.code);
end
$$;

-- Delete rooms nobody has touched for p_hours hours; returns how many.
create or replace function public.ti_admin_cleanup(p_hours int)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  v_n int;
begin
  perform public.ti_require_admin();
  with gone as (
    delete from public.ti_rooms r
    where greatest(r.updated_at, coalesce((select max(p.last_seen) from public.ti_players p where p.room = r.code), r.updated_at))
          < now() - make_interval(hours => greatest(1, coalesce(p_hours, 2)))
    returning 1)
  select count(*) into v_n from gone;
  return v_n;
end
$$;

do $$
declare
  f text;
begin
  foreach f in array array['ti_is_admin()', 'ti_admin_unlock(text)', 'ti_admin_lock()', 'ti_admin_set_password(text, text)',
    'ti_admin_overview()', 'ti_admin_delete_room(text)', 'ti_admin_end_game(text)', 'ti_admin_kick(text, uuid)', 'ti_admin_cleanup(int)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end
$$;
revoke execute on function public.ti_require_admin() from public, anon, authenticated;

-- The suggestion deck moves into the database (the admin can edit it), new
-- scales players write are kept for review, and a small game log for stats.

-- ---------------------------------------------------------------- deck
create table if not exists public.ti_deck (
  id bigint generated always as identity primary key,
  left_label text not null check (length(left_label) between 1 and 40),
  right_label text not null check (length(right_label) between 1 and 40),
  clue text not null check (length(clue) between 1 and 80),
  hidden boolean not null default false,
  source text not null default 'builtin' check (source in ('builtin', 'player', 'admin')),
  created_at timestamptz not null default now()
);
create unique index if not exists ti_deck_unique on public.ti_deck (lower(left_label), lower(right_label), lower(clue));
alter table public.ti_deck enable row level security;

insert into public.ti_deck (left_label, right_label, clue) values
  ('Quiet place', 'Loud place', 'A library on a Sunday morning'),
  ('Naughty', 'Nice', 'Eating the last slice without asking'),
  ('Cold', 'Hot', 'A mug of mulled wine'),
  ('Worst Christmas song', 'Best Christmas song', 'Last Christmas'),
  ('Overrated film', 'Underrated film', 'Love Actually'),
  ('Easy to wrap', 'Impossible to wrap', 'A bicycle'),
  ('Healthy', 'Unhealthy', 'A big slice of cake'),
  ('Cheap date', 'Fancy date', 'A picnic in the park'),
  ('Unromantic', 'Romantic', 'Watching football together'),
  ('Calm', 'Chaos', 'A kitchen while baking cookies'),
  ('Useless gift', 'Perfect gift', 'Fluffy socks'),
  ('Scary', 'Cozy', 'A snowstorm outside the window'),
  ('Childish', 'Grown-up', 'Building a snowman'),
  ('Terrible singer', 'Amazing singer', 'Me singing in the car'),
  ('Morning person', 'Night owl', 'A teenager on holiday'),
  ('Never', 'All the time', 'Checking my phone'),
  ('Bad idea', 'Great idea', 'A tattoo of your partner’s name'),
  ('Boring', 'Exciting', 'Untangling Christmas lights'),
  ('Tiny', 'Huge', 'A hamster'),
  ('Slow', 'Fast', 'A sloth on roller skates'),
  ('Old-fashioned', 'Trendy', 'Writing letters by hand'),
  ('Easy', 'Hard', 'Assembling flat-pack furniture'),
  ('Dangerous', 'Safe', 'Skydiving'),
  ('Smells bad', 'Smells great', 'Fresh bread'),
  ('Lazy', 'Exhausting', 'Moving house'),
  ('Mild', 'Spicy', 'Ketchup'),
  ('Relaxing', 'Stressful', 'A family dinner'),
  ('Villain', 'Hero', 'The Grinch'),
  ('Indoor', 'Outdoor', 'Table tennis'),
  ('Forgettable', 'Unforgettable', 'Your first kiss'),
  ('Waste of money', 'Worth every penny', 'A good mattress'),
  ('Cringe', 'Cool', 'Socks with sandals'),
  ('Rude', 'Polite', 'Leaving a group chat'),
  ('Beginner', 'Expert', 'Me at cooking'),
  ('Normal pet', 'Unusual pet', 'A tarantula'),
  ('Bad superpower', 'Great superpower', 'Talking to fish'),
  ('Tastes bad', 'Tastes great', 'Pineapple on pizza'),
  ('Background character', 'Main character', 'The person who always has snacks'),
  ('Junk food', 'Gourmet food', 'Sushi from a petrol station'),
  ('Ancient', 'Futuristic', 'A fax machine'),
  ('Quiet', 'Loud', 'A library on a Sunday morning'),
  ('Cheap', 'Expensive', 'A cinema ticket'),
  ('Overrated', 'Underrated', 'Brunch'),
  ('Bad gift', 'Great gift', 'Fluffy socks'),
  ('Cozy', 'Scary', 'A snowstorm outside the window'),
  ('Calm', 'Chaotic', 'A kitchen while baking cookies'),
  ('Ugly', 'Beautiful', 'A pug'),
  ('Useless', 'Essential', 'A phone charger'),
  ('Sad song', 'Happy song', 'Hey Jude'),
  ('Bad film', 'Great film', 'Titanic'),
  ('Weird food', 'Normal food', 'Pineapple on pizza'),
  ('Rare', 'Common', 'A four-leaf clover'),
  ('Lazy activity', 'Exhausting activity', 'Moving house'),
  ('Morning thing', 'Night thing', 'Brushing your teeth'),
  ('Soft', 'Hard', 'An avocado'),
  ('Sweet', 'Savoury', 'Popcorn'),
  ('Bad habit', 'Good habit', 'Biting your nails'),
  ('Introvert activity', 'Extrovert activity', 'Karaoke'),
  ('Summer', 'Winter', 'Ice cream'),
  ('Underdressed', 'Overdressed', 'A suit at a barbecue'),
  ('Simple', 'Complicated', 'Tax returns'),
  ('Worst holiday food', 'Best holiday food', 'Fruitcake'),
  ('Low effort gift', 'High effort gift', 'A gift card'),
  ('Bad idea at a party', 'Great idea at a party', 'Bringing a guitar'),
  ('Fragile', 'Indestructible', 'An old Nokia phone'),
  ('Dirty', 'Clean', 'A teenager’s bedroom'),
  ('Unknown', 'Famous', 'Your local baker'),
  ('Fiction', 'Real', 'The Loch Ness monster'),
  ('Silent', 'Noisy hobby', 'Knitting'),
  ('Mundane', 'Magical', 'The northern lights'),
  ('Short-lived', 'Lasts forever', 'A New Year’s resolution'),
  ('Hated chore', 'Loved chore', 'Ironing'),
  ('Cat person thing', 'Dog person thing', 'Going for a run'),
  ('Ordinary', 'Luxurious', 'A bubble bath'),
  ('Easy to learn', 'Hard to learn', 'Juggling'),
  ('Sounds made up', 'Sounds real', 'A platypus'),
  ('Peaceful', 'Violent', 'A pillow fight'),
  ('Underground', 'Mainstream', 'Vinyl records'),
  ('Plain', 'Fancy', 'Toast with butter'),
  ('Wet', 'Dry', 'A cat after a bath'),
  ('Harmless', 'Deadly', 'A jellyfish'),
  ('Square', 'Round', 'A pizza box'),
  ('Dark', 'Bright', 'A cinema during the film'),
  ('Sour', 'Sweet', 'A lemon tart'),
  ('Scary film', 'Feel-good film', 'Home Alone'),
  ('Lame party', 'Legendary party', 'An office party'),
  ('Basic', 'Exotic', 'Dragon fruit'),
  ('Mild weather', 'Extreme weather', 'A November day'),
  ('Light', 'Heavy', 'A duvet'),
  ('Bad at hiding', 'Good at hiding', 'A toddler playing hide-and-seek'),
  ('Low stakes', 'High stakes', 'Choosing a restaurant'),
  ('Unpopular opinion', 'Popular opinion', 'Winter is the best season'),
  ('Needs no skill', 'Needs lots of skill', 'Parallel parking'),
  ('Smooth', 'Rough', 'A cat’s tongue'),
  ('Bad first date', 'Great first date', 'Bowling'),
  ('Grandma would hate it', 'Grandma would love it', 'A nose piercing'),
  ('Cheap thrill', 'Once in a lifetime', 'Seeing a shooting star'),
  ('Everyday item', 'Collector''s item', 'A Pokémon card'),
  ('Socially awkward', 'Smooth talker', 'Me at a wedding'),
  ('Normal Tuesday', 'Best day ever', 'A snow day off school'),
  ('Bad smell', 'Good smell', 'A wet dog'),
  ('Sleepy', 'Energetic', 'A cat at 3 am'),
  ('Unhelpful', 'Helpful', 'Autocorrect'),
  ('Tacky decoration', 'Classy decoration', 'An inflatable Santa'),
  ('Overcooked', 'Undercooked', 'A medium-rare steak'),
  ('Gentle', 'Fierce', 'A goose'),
  ('Snack', 'Meal', 'A bowl of cereal'),
  ('Short trip', 'Long trip', 'A weekend in Vienna'),
  ('Unlucky', 'Lucky', 'Finding money in old jeans'),
  ('Mess', 'Masterpiece', 'My handwriting'),
  ('Not romantic', 'Very romantic', 'Breakfast in bed'),
  ('Red flag', 'Green flag', 'Texting back instantly'),
  ('Dealbreaker', 'Dream partner', 'Snoring'),
  ('Low effort', 'High effort', 'A handwritten love letter'),
  ('Awkward first date', 'Perfect first date', 'Mini golf'),
  ('Too soon', 'Perfect timing', 'Saying “I love you” after a month'),
  ('Cringey pet name', 'Cute pet name', '“Babe”'),
  ('Unforgivable', 'Easily forgiven', 'Forgetting an anniversary'),
  ('Couple goals', 'Couple fail', 'Matching outfits'),
  ('Only friends do it', 'Only couples do it', 'Sharing a dessert'),
  ('Boring night in', 'Perfect night in', 'Takeaway and a film'),
  ('Keep it private', 'Share with everyone', 'Posting couple selfies'),
  ('Totally chill', 'Very jealous', 'Your partner liking an ex’s photo'),
  ('Terrible gift for a partner', 'Perfect gift for a partner', 'A vacuum cleaner'),
  ('Rarely', 'Constantly', 'Saying “I’m fine” when you’re not'),
  ('Easy to agree on', 'Impossible to agree on', 'Where to eat tonight'),
  ('Unattractive habit', 'Attractive habit', 'Cooking for someone'),
  ('Clingy', 'Independent', 'Texting goodnight every night'),
  ('Great first-date topic', 'Never on a first date', 'Your ex'),
  ('Small gesture', 'Grand gesture', 'Flowers for no reason'),
  ('Starts a fight', 'Ends a fight', '“We need to talk”'),
  ('Sweet', 'Way over the top', 'A proposal on the big screen at a match'),
  ('Boring couple activity', 'Fun couple activity', 'Grocery shopping together'),
  ('Minor annoyance', 'Relationship ender', 'Dishes left in the sink'),
  ('Easy to say', 'Hard to say', '“Sorry”'),
  ('Just friends', 'Soulmates', 'Best friends for ten years'),
  ('Hates surprises', 'Loves surprises', 'Me'),
  ('Unromantic place', 'Romantic place', 'IKEA'),
  ('Bad advice', 'Great advice', '“Never go to bed angry”'),
  ('Lazy Sunday', 'Adventurous Sunday', 'A long walk together'),
  ('Least important in a partner', 'Most important in a partner', 'A sense of humour'),
  ('Petty argument', 'Serious argument', 'Who ate the last biscuit'),
  ('Cheesy line', 'Smooth line', '“Are you a magician?”'),
  ('Happy to share', 'Never sharing', 'My fries'),
  ('Weird thing couples do', 'Normal thing couples do', 'Giving each other nicknames'),
  ('Always forgets', 'Never forgets', 'Our anniversary'),
  ('Wouldn’t do it for love', 'Would do it for love', 'Moving to another country'),
  ('Sweet', 'Too much', 'Five good-morning texts'),
  ('Fleeting crush', 'True love', 'A holiday romance'),
  ('Embarrassing', 'Adorable', 'Singing to your partner in public'),
  ('Least romantic month', 'Most romantic month', 'February'),
  ('Doesn’t matter', 'Matters a lot', 'Who pays on a first date'),
  ('Terrible cook', 'Master chef', 'My partner'),
  ('Bad listener', 'Great listener', 'Me when football is on'),
  ('Low-key', 'Extra', 'A surprise birthday party'),
  ('Turn-off', 'Charming', 'Being rude to waiters'),
  ('Ruins a friendship', 'Builds a friendship', 'A road trip together'),
  ('Easy to keep', 'Impossible to keep', 'A secret from your partner'),
  ('No big deal', 'Huge deal', 'Meeting the parents'),
  ('Grumpy', 'Cuddly', 'Me in the morning'),
  ('Bad at texting', 'Great at texting', 'Replying with “k”'),
  ('Total stranger', 'Basically family', 'My partner’s best friend'),
  ('Annoying', 'Endearing', 'Stealing the duvet'),
  ('Wild night out', 'Cosy evening', 'A double date'),
  ('Boring date idea', 'Creative date idea', 'A cooking class'),
  ('Never', 'Every single day', 'Saying “I love you”'),
  ('Bad relationship advice', 'Good relationship advice', '“Keep score”'),
  ('Forgettable moment', 'Unforgettable moment', 'Our first trip together'),
  ('Easy chore to share', 'Chore worth fighting over', 'Taking out the bins'),
  ('White lie', 'Big lie', '“I love the jumper you knitted”'),
  ('Needs no reason', 'Needs a big reason', 'Buying flowers'),
  ('Not cute', 'Very cute', 'An old couple holding hands'),
  ('Bad for a relationship', 'Good for a relationship', 'Separate hobbies'),
  ('Reply instantly', 'Leave on read', 'A meme at 2 am'),
  ('Relaxing trip together', 'Stressful trip together', 'Camping'),
  ('Every day', 'Special occasions only', 'Wearing your best perfume'),
  ('Anti-romance film', 'Romance film', 'The Notebook'),
  ('Spontaneous', 'Carefully planned', 'A weekend getaway'),
  ('Totally private', 'Public display of affection', 'Holding hands'),
  ('Easy to impress', 'Hard to impress', 'Your partner’s mum'),
  ('Small talk', 'Deep talk', '“Do you want kids one day?”'),
  ('Cute couple habit', 'Annoying couple habit', 'Finishing each other’s sentences'),
  ('Calm animal', 'Chaotic animal', 'A raccoon'),
  ('Silly', 'Serious', 'A tie with ducks on it'),
  ('Wallflower', 'Life of the party', 'My uncle at weddings'),
  ('Underrated snack', 'Overrated snack', 'Avocado toast'),
  ('Worst season', 'Best season', 'Autumn'),
  ('Cheap holiday', 'Dream holiday', 'A week in Iceland'),
  ('Bad pet name', 'Great pet name', 'Mr. Whiskers'),
  ('Overpriced', 'Bargain', 'Water at the airport'),
  ('Easy to draw', 'Hard to draw', 'A horse'),
  ('Hidden talent', 'Obvious talent', 'Whistling'),
  ('Guilty pleasure', 'Proud pleasure', 'Reality TV'),
  ('Sounds tasty', 'Sounds disgusting', 'Pickle ice cream'),
  ('Kids love it', 'Adults love it', 'Brussels sprouts'),
  ('Pointless invention', 'Life-changing invention', 'The selfie stick'),
  ('Normal Saturday', 'Perfect Saturday', 'Sleeping until noon'),
  ('Weak', 'Strong', 'An espresso'),
  ('Homebody', 'Globetrotter', 'A tortoise'),
  ('Calm job', 'Stressful job', 'Air traffic controller'),
  ('Boring job', 'Dream job', 'Professional taste tester'),
  ('Useless skill', 'Useful skill', 'Speaking Latin'),
  ('Cheap hobby', 'Expensive hobby', 'Golf'),
  ('Boring to watch', 'Thrilling to watch', 'Curling'),
  ('Morning drink', 'Evening drink', 'Hot chocolate'),
  ('Soft-spoken', 'Very loud', 'A drill sergeant'),
  ('Not scary', 'Terrifying', 'A clown at night'),
  ('Cute animal', 'Ugly animal', 'A naked mole rat'),
  ('Ordinary sandwich', 'Legendary sandwich', 'A cheese toastie'),
  ('Easy to pronounce', 'Hard to pronounce', 'Worcestershire'),
  ('Myth', 'Fact', 'Goldfish have a three-second memory'),
  ('Only tasty at 3 am', 'Tasty any time', 'Cold pizza'),
  ('Calming sound', 'Annoying sound', 'A ticking clock'),
  ('Classy drink', 'Trashy drink', 'Boxed wine'),
  ('Useless app', 'Essential app', 'A torch app'),
  ('Normal fear', 'Weird fear', 'Fear of buttons'),
  ('Too short', 'Too long', 'A three-hour film'),
  ('Bad gift for a boss', 'Good gift for a boss', 'A mug'),
  ('Overrated city', 'Underrated city', 'Paris'),
  ('Weird collection', 'Normal collection', 'Collecting spoons'),
  ('Timeless', 'Dated', 'Skinny jeans'),
  ('Annoying song', 'Great song', 'Baby Shark'),
  ('Kid-friendly', 'Adults only', 'A water park'),
  ('Bad picnic weather', 'Perfect picnic weather', 'A light drizzle'),
  ('Smells like childhood', 'Smells like adulthood', 'Crayons'),
  ('Rarely used', 'Used every day', 'The dishwasher'),
  ('Boring holiday', 'Exciting holiday', 'A cruise'),
  ('Easy to forget', 'Hard to forget', 'The Wi-Fi password'),
  ('Good in theory', 'Good in practice', 'The gym at 6 am'),
  ('Clumsy', 'Athletic', 'Me at bowling'),
  ('Underpaid', 'Overpaid', 'Footballers'),
  ('Tasty combo', 'Weird combo', 'Fries dipped in milkshake'),
  ('Chill game', 'Rage game', 'Monopoly'),
  ('Normal breakfast', 'Weird breakfast', 'Pizza for breakfast'),
  ('Bad life advice', 'Great life advice', '“Just be yourself”'),
  ('Mild inconvenience', 'Total disaster', 'Losing your keys'),
  ('Lazy weekend', 'Productive weekend', 'Cleaning the whole house'),
  ('Old person thing', 'Young person thing', 'Doing crosswords'),
  ('Useless in a zombie apocalypse', 'Essential in a zombie apocalypse', 'A frying pan'),
  ('Boring superpower', 'Amazing superpower', 'Never getting lost'),
  ('Easy dance', 'Hard dance', 'The Macarena'),
  ('Cheap date snack', 'Fancy date snack', 'Strawberries and champagne'),
  ('Never regift', 'Perfect to regift', 'Scented candles'),
  ('Better hot', 'Better cold', 'Pizza'),
  ('Nobody likes it', 'Everybody likes it', 'Coriander'),
  ('Pointless on holiday', 'Essential on holiday', 'A travel pillow'),
  ('Quick fix', 'Long-term solution', 'Duct tape'),
  ('Polite on a train', 'Rude on a train', 'Eating a tuna sandwich'),
  ('Not worth the hype', 'Worth the hype', 'Hot yoga'),
  ('Ancient history', 'Feels like yesterday', 'The year 2010'),
  ('Plain', 'Over the top', 'A gender reveal party'),
  ('Bad to binge', 'Perfect to binge', 'A cooking show')
on conflict do nothing;

-- Scales players wrote that aren't in the deck, waiting for the admin.
create table if not exists public.ti_scale_submissions (
  id bigint generated always as identity primary key,
  left_label text not null,
  right_label text not null,
  clue text not null,
  by_name text,
  uses int not null default 1,
  status text not null default 'pending' check (status in ('pending', 'dismissed')),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now()
);
create unique index if not exists ti_submissions_unique on public.ti_scale_submissions (lower(left_label), lower(right_label), lower(clue));
alter table public.ti_scale_submissions enable row level security;

-- ---------------------------------------------------------------- game log
-- Kept after rooms are deleted, for the admin's history.
create table if not exists public.ti_game_log (
  id bigint generated always as identity primary key,
  room text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  rounds_played int not null default 0,
  players int not null default 0
);
create index if not exists ti_game_log_room on public.ti_game_log (room, id desc);
create table if not exists public.ti_round_log (
  at timestamptz not null default now(),
  room text not null,
  left_label text not null,
  right_label text not null,
  clue text
);
alter table public.ti_game_log enable row level security;
alter table public.ti_round_log enable row level security;

create or replace function public.ti_log_room()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.ti_game_log (room) values (new.code);
  elsif new.status = 'finished' and old.status <> 'finished' then
    update public.ti_game_log set finished_at = now()
      where id = (select max(id) from public.ti_game_log where room = new.code);
  elsif old.status = 'finished' and new.status = 'playing' then
    insert into public.ti_game_log (room, players)
      values (new.code, (select count(*) from public.ti_players where room = new.code and left_at is null));
  end if;
  return null;
end
$$;
drop trigger if exists ti_log_room on public.ti_rooms;
create trigger ti_log_room after insert or update of status on public.ti_rooms
  for each row execute function public.ti_log_room();

create or replace function public.ti_log_players()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  update public.ti_game_log
    set players = greatest(players, (select count(*) from public.ti_players where room = new.room and left_at is null))
    where id = (select max(id) from public.ti_game_log where room = new.room);
  return null;
end
$$;
drop trigger if exists ti_log_players on public.ti_players;
create trigger ti_log_players after insert or update of left_at on public.ti_players
  for each row execute function public.ti_log_players();

-- When a round is sent: log the scale, and keep it for review if it's new.
-- When it's revealed: count it as played.
create or replace function public.ti_log_round()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.phase = 'clue' and new.phase = 'guessing' then
    insert into public.ti_round_log (room, left_label, right_label, clue) values (new.room, new.left_label, new.right_label, new.clue);
    if new.clue is not null and not exists (
      select 1 from public.ti_deck d
      where lower(d.left_label) = lower(new.left_label) and lower(d.right_label) = lower(new.right_label) and lower(d.clue) = lower(new.clue)
    ) then
      insert into public.ti_scale_submissions (left_label, right_label, clue, by_name)
        values (new.left_label, new.right_label, new.clue,
                (select p.name from public.ti_players p where p.room = new.room and p.user_id = new.psychic))
        on conflict (lower(left_label), lower(right_label), lower(clue))
        do update set uses = public.ti_scale_submissions.uses + 1, last_at = now();
    end if;
  elsif new.phase = 'reveal' and old.phase <> 'reveal' then
    update public.ti_game_log set rounds_played = rounds_played + 1
      where id = (select max(id) from public.ti_game_log where room = new.room);
  end if;
  return null;
end
$$;
drop trigger if exists ti_log_round on public.ti_rounds;
create trigger ti_log_round after update of phase on public.ti_rounds
  for each row execute function public.ti_log_round();

-- Existing rooms get a log row so they show up.
insert into public.ti_game_log (room, started_at, players)
  select r.code, r.created_at, (select count(*) from public.ti_players p where p.room = r.code and p.left_at is null)
  from public.ti_rooms r where not exists (select 1 from public.ti_game_log g where g.room = r.code);

-- ---------------------------------------------------------------- players
-- The 🎲 suggestions (everything not hidden).
create or replace function public.ti_suggestions()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('left', left_label, 'right', right_label, 'clue', clue) order by id), '[]'::jsonb)
  from public.ti_deck where not hidden
$$;

-- ---------------------------------------------------------------- admin
create or replace function public.ti_admin_stats()
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  return jsonb_build_object(
    'games', (select count(*) from public.ti_game_log),
    'finished', (select count(*) from public.ti_game_log where finished_at is not null),
    'rounds', (select coalesce(sum(rounds_played), 0) from public.ti_game_log),
    'games_week', (select count(*) from public.ti_game_log where started_at > now() - interval '7 days'),
    'avg_players', (select round(avg(players), 1) from public.ti_game_log where players > 0),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'games', (
        select count(*) from public.ti_game_log g where g.started_at >= d and g.started_at < d + interval '1 day')) order by d)
      from generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') d), '[]'::jsonb),
    'top_scales', coalesce((
      select jsonb_agg(x order by x->>'uses' desc) from (
        select jsonb_build_object('left', min(left_label), 'right', min(right_label), 'uses', count(*)) x
        from public.ti_round_log group by lower(left_label), lower(right_label)
        order by count(*) desc limit 10) t), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('room', room, 'started_at', started_at, 'finished_at', finished_at,
                                          'rounds', rounds_played, 'players', players) order by id desc)
      from (select * from public.ti_game_log order by id desc limit 15) g), '[]'::jsonb)
  );
end
$$;

create or replace function public.ti_admin_deck()
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  return jsonb_build_object(
    'deck', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'left', left_label, 'right', right_label, 'clue', clue,
                                                          'hidden', hidden, 'source', source) order by id desc)
                      from public.ti_deck), '[]'::jsonb),
    'pending', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'left', s.left_label, 'right', s.right_label, 'clue', s.clue,
                                                             'by', s.by_name, 'uses', s.uses, 'last_at', s.last_at,
                                                             'new_scale', not exists (select 1 from public.ti_deck d
                                                               where lower(d.left_label) = lower(s.left_label) and lower(d.right_label) = lower(s.right_label)))
                                          order by s.last_at desc)
                         from public.ti_scale_submissions s where s.status = 'pending'), '[]'::jsonb)
  );
end
$$;

-- Add (p_id null) or edit a deck entry.
create or replace function public.ti_admin_deck_save(p_id bigint, p_left text, p_right text, p_clue text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_left text := left(regexp_replace(trim(coalesce(p_left, '')), '\s+', ' ', 'g'), 40);
  v_right text := left(regexp_replace(trim(coalesce(p_right, '')), '\s+', ' ', 'g'), 40);
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  perform public.ti_require_admin();
  if v_left = '' or v_right = '' or v_clue = '' then
    raise exception 'Fill in both ends and the clue';
  end if;
  if exists (select 1 from public.ti_deck where lower(left_label) = lower(v_left) and lower(right_label) = lower(v_right)
             and lower(clue) = lower(v_clue) and id is distinct from p_id) then
    raise exception 'That scale and clue are already in the deck';
  end if;
  if p_id is null then
    insert into public.ti_deck (left_label, right_label, clue, source) values (v_left, v_right, v_clue, 'admin');
  else
    update public.ti_deck set left_label = v_left, right_label = v_right, clue = v_clue where id = p_id;
  end if;
end
$$;

create or replace function public.ti_admin_deck_hide(p_id bigint, p_hidden boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  update public.ti_deck set hidden = p_hidden where id = p_id;
end
$$;

create or replace function public.ti_admin_deck_delete(p_id bigint)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  delete from public.ti_deck where id = p_id;
end
$$;

-- Accept a player's scale into the deck (optionally edited first).
create or replace function public.ti_admin_submission_accept(p_id bigint, p_left text, p_right text, p_clue text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_left text := left(regexp_replace(trim(coalesce(p_left, '')), '\s+', ' ', 'g'), 40);
  v_right text := left(regexp_replace(trim(coalesce(p_right, '')), '\s+', ' ', 'g'), 40);
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  perform public.ti_require_admin();
  if v_left = '' or v_right = '' or v_clue = '' then
    raise exception 'Fill in both ends and the clue';
  end if;
  insert into public.ti_deck (left_label, right_label, clue, source) values (v_left, v_right, v_clue, 'player')
    on conflict do nothing;
  delete from public.ti_scale_submissions where id = p_id;
end
$$;

-- Not for the deck: stays out of the review list even if it's used again.
create or replace function public.ti_admin_submission_dismiss(p_id bigint)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform public.ti_require_admin();
  update public.ti_scale_submissions set status = 'dismissed' where id = p_id;
end
$$;

-- Watch any room as a silent spectator. The secret spot and locked guesses are
-- included; the page keeps them covered until the admin chooses to look.
create or replace function public.ti_admin_room_state(p_code text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r public.ti_rooms;
  rd public.ti_rounds;
begin
  perform public.ti_require_admin();
  select * into r from public.ti_rooms where code = upper(trim(coalesce(p_code, '')));
  if r.code is null then
    return jsonb_build_object('missing', true);
  end if;
  select * into rd from public.ti_rounds where room = r.code and n = r.round;
  return jsonb_build_object(
    'code', r.code,
    'host', r.host,
    'status', r.status,
    'round', r.round,
    'rounds_total', r.rounds_total,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.user_id, 'name', p.name, 'seat', p.seat, 'score', p.score,
                                          'online', p.last_seen > now() - interval '45 seconds') order by p.seat)
      from public.ti_active_players(r.code) p), '[]'::jsonb),
    'current', case when rd.room is null then null else jsonb_build_object(
      'n', rd.n, 'psychic', rd.psychic, 'left', rd.left_label, 'right', rd.right_label, 'clue', rd.clue, 'phase', rd.phase,
      'precision', coalesce(rd.precision, r.precision),
      'target', (select target from public.ti_round_secrets s where s.room = r.code and s.n = rd.n),
      'guesses', coalesce((select jsonb_agg(jsonb_build_object('user_id', g.user_id, 'value', g.value, 'points', g.points))
                           from public.ti_guesses g where g.room = r.code and g.n = rd.n), '[]'::jsonb)
    ) end
  );
end
$$;

do $$
declare
  f text;
begin
  foreach f in array array['ti_suggestions()', 'ti_admin_stats()', 'ti_admin_deck()', 'ti_admin_deck_save(bigint, text, text, text)',
    'ti_admin_deck_hide(bigint, boolean)', 'ti_admin_deck_delete(bigint)', 'ti_admin_submission_accept(bigint, text, text, text)',
    'ti_admin_submission_dismiss(bigint)', 'ti_admin_room_state(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['ti_log_room()', 'ti_log_players()', 'ti_log_round()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end
$$;

