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

create table public.cards (
  id serial primary key,
  left_label text not null,
  right_label text not null
);

create table public.rooms (
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

create table public.room_players (
  room text not null references public.rooms (code) on delete cascade,
  user_id uuid not null,
  name text not null check (length(name) between 1 and 24),
  seat int not null,
  score numeric not null default 0,
  last_seen timestamptz not null default now(),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (room, user_id)
);

create table public.room_cards (
  id bigint generated always as identity primary key,
  room text not null references public.rooms (code) on delete cascade,
  left_label text not null check (length(left_label) between 1 and 40),
  right_label text not null check (length(right_label) between 1 and 40),
  added_by uuid not null
);

create table public.rounds (
  room text not null references public.rooms (code) on delete cascade,
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

create table public.round_secrets (
  room text not null,
  n int not null,
  target numeric not null,
  primary key (room, n),
  foreign key (room, n) references public.rounds (room, n) on delete cascade
);

create table public.guesses (
  room text not null,
  n int not null,
  user_id uuid not null,
  value numeric not null check (value between 0 and 100),
  points numeric,
  locked_at timestamptz not null default now(),
  primary key (room, n, user_id),
  foreign key (room, n) references public.rounds (room, n) on delete cascade
);

-- One row per room; every change bumps `tick` so phones know to refresh.
create table public.room_ticks (
  room text primary key references public.rooms (code) on delete cascade,
  tick bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.cards enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.room_cards enable row level security;
alter table public.rounds enable row level security;
alter table public.round_secrets enable row level security;
alter table public.guesses enable row level security;
alter table public.room_ticks enable row level security;

-- Only the tick is readable directly (for Realtime), and only by the room's players.
create or replace function public.is_room_member(p_room text)
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.room_players where room = p_room and user_id = auth.uid()) $$;

create policy "members see their room's tick" on public.room_ticks for select to authenticated
  using (public.is_room_member(room));
grant select on public.room_ticks to authenticated;

alter publication supabase_realtime add table public.room_ticks;

-- ---------------------------------------------------------------- helpers

create or replace function public.bump(p_room text)
returns void language sql security definer set search_path = ''
as $$
  update public.room_ticks set tick = tick + 1, updated_at = now() where room = p_room;
  update public.rooms set updated_at = now() where code = p_room;
$$;

create or replace function public.active_players(p_room text)
returns setof public.room_players language sql stable security definer set search_path = ''
as $$ select * from public.room_players where room = p_room and left_at is null order by seat $$;

create or replace function public.require_member(p_room text)
returns public.rooms language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  select * into r from public.rooms where code = upper(p_room) for update;
  if r.code is null then
    raise exception 'That room doesn''t exist (anymore)';
  end if;
  if not exists (select 1 from public.room_players where room = r.code and user_id = auth.uid() and left_at is null) then
    raise exception 'You''re not in this room';
  end if;
  return r;
end
$$;

create or replace function public.clean_name(p_name text)
returns text language sql immutable set search_path = ''
as $$ select left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 24) $$;

-- Points for one guess: 4 in the middle band, then 3, then 2.
create or replace function public.points_for(p_guess numeric, p_target numeric, p_tol numeric)
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
create or replace function public.deal(p_room text, p_n int)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c record;
begin
  select * into c from (
    select 'c' || id as key, left_label, right_label from public.cards
    union all
    select 'r' || id, left_label, right_label from public.room_cards where room = p_room
  ) all_cards
  where key not in (select card_key from public.rounds where room = p_room and n <> p_n)
  order by random() limit 1;
  if c.key is null then
    -- Every card has been used: allow repeats.
    select 'c' || id as key, left_label, right_label into c from public.cards order by random() limit 1;
  end if;
  update public.rounds set card_key = c.key, left_label = c.left_label, right_label = c.right_label
    where room = p_room and n = p_n;
  insert into public.round_secrets (room, n, target) values (p_room, p_n, round((3 + random() * 94)::numeric, 1))
    on conflict (room, n) do update set target = excluded.target;
end
$$;

create or replace function public.start_round(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  v_n int;
  v_count int;
  v_psychic uuid;
begin
  select * into r from public.rooms where code = p_room;
  v_n := r.round + 1;
  if v_n > r.rounds_total then
    update public.rooms set status = 'finished' where code = p_room;
    return;
  end if;
  select count(*) into v_count from public.active_players(p_room);
  select user_id into v_psychic from public.active_players(p_room) offset ((v_n - 1) % greatest(v_count, 1)) limit 1;
  insert into public.rounds (room, n, psychic, card_key, left_label, right_label)
    values (p_room, v_n, v_psychic, '', '', '');
  perform public.deal(p_room, v_n);
  update public.rooms set round = v_n where code = p_room;
end
$$;

-- Score the round: guessers by band, the psychic gets the guessers' average.
create or replace function public.reveal(p_room text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
  v_target numeric;
  v_avg numeric;
begin
  select * into r from public.rooms where code = p_room;
  select * into rd from public.rounds where room = p_room and n = r.round;
  if rd.phase <> 'guessing' then
    return;
  end if;
  select target into v_target from public.round_secrets where room = p_room and n = rd.n;
  update public.guesses g set points = public.points_for(g.value, v_target, r.precision)
    where g.room = p_room and g.n = rd.n;
  update public.room_players p set score = p.score + g.points
    from public.guesses g where g.room = p_room and g.n = rd.n and p.room = p_room and p.user_id = g.user_id;
  select coalesce(round(avg(points) * 2) / 2, 0) into v_avg from public.guesses where room = p_room and n = rd.n;
  update public.room_players set score = score + v_avg where room = p_room and user_id = rd.psychic;
  update public.rounds set phase = 'reveal' where room = p_room and n = rd.n;
end
$$;

-- ---------------------------------------------------------------- actions

create or replace function public.create_room(p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text;
  v_name text := public.clean_name(p_name);
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  -- Tidy up rooms nobody has touched for two days.
  delete from public.rooms where updated_at < now() - interval '2 days';
  loop
    v_code := (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 5));
    exit when not exists (select 1 from public.rooms where code = v_code);
  end loop;
  insert into public.rooms (code, host) values (v_code, auth.uid());
  insert into public.room_players (room, user_id, name, seat) values (v_code, auth.uid(), v_name, 0);
  insert into public.room_ticks (room) values (v_code);
  return v_code;
end
$$;

create or replace function public.join_room(p_code text, p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_name text := public.clean_name(p_name);
begin
  if auth.uid() is null then
    raise exception 'Please reload the page';
  end if;
  if v_name = '' then
    raise exception 'Enter your name first';
  end if;
  perform 1 from public.rooms where code = v_code for update;
  if not found then
    raise exception 'No room with the code %', v_code;
  end if;
  if exists (select 1 from public.room_players where room = v_code and user_id = auth.uid()) then
    update public.room_players set name = v_name, left_at = null, last_seen = now() where room = v_code and user_id = auth.uid();
  else
    if (select count(*) from public.active_players(v_code)) >= 12 then
      raise exception 'This room is full (12 players)';
    end if;
    if exists (select 1 from public.active_players(v_code) where lower(name) = lower(v_name)) then
      raise exception 'Someone in this room is already called %', v_name;
    end if;
    insert into public.room_players (room, user_id, name, seat)
      values (v_code, auth.uid(), v_name, coalesce((select max(seat) + 1 from public.room_players where room = v_code), 0));
  end if;
  perform public.bump(v_code);
  return v_code;
end
$$;

create or replace function public.leave_room(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  v_next uuid;
begin
  r := public.require_member(p_code);
  update public.room_players set left_at = now() where room = r.code and user_id = auth.uid();
  if r.host = auth.uid() then
    select user_id into v_next from public.active_players(r.code) limit 1;
    if v_next is null then
      delete from public.rooms where code = r.code;
      return;
    end if;
    update public.rooms set host = v_next where code = r.code;
  end if;
  perform public.bump(r.code);
end
$$;

create or replace function public.update_settings(p_code text, p_rounds_per_player int, p_precision int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can change the settings';
  end if;
  if r.status <> 'lobby' then
    raise exception 'The game has already started';
  end if;
  update public.rooms set rounds_per_player = p_rounds_per_player, precision = p_precision where code = r.code;
  perform public.bump(r.code);
end
$$;

create or replace function public.add_card(p_code text, p_left text, p_right text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  if coalesce(trim(p_left), '') = '' or coalesce(trim(p_right), '') = '' then
    raise exception 'Fill in both ends of the scale';
  end if;
  if (select count(*) from public.room_cards where room = r.code) >= 60 then
    raise exception 'That''s plenty of custom scales for one room';
  end if;
  insert into public.room_cards (room, left_label, right_label, added_by) values (r.code, left(trim(p_left), 40), left(trim(p_right), 40), auth.uid());
  perform public.bump(r.code);
end
$$;

create or replace function public.remove_card(p_code text, p_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  delete from public.room_cards where room = r.code and id = p_id and (added_by = auth.uid() or r.host = auth.uid());
  perform public.bump(r.code);
end
$$;

create or replace function public.start_game(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  v_count int;
begin
  r := public.require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can start the game';
  end if;
  if r.status = 'playing' then
    return;
  end if;
  select count(*) into v_count from public.active_players(r.code);
  if v_count < 2 then
    raise exception 'You need at least 2 players';
  end if;
  delete from public.rounds where room = r.code;
  update public.room_players set score = 0 where room = r.code;
  update public.rooms set status = 'playing', round = 0, rounds_total = v_count * r.rounds_per_player where code = r.code;
  perform public.start_round(r.code);
  perform public.bump(r.code);
end
$$;

create or replace function public.skip_card(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
begin
  r := public.require_member(p_code);
  select * into rd from public.rounds where room = r.code and n = r.round;
  if rd.psychic <> auth.uid() or rd.phase <> 'clue' then
    raise exception 'Only the psychic can draw another card, before giving a clue';
  end if;
  if rd.skips >= 3 then
    raise exception 'No more redraws this round';
  end if;
  update public.rounds set skips = skips + 1 where room = r.code and n = rd.n;
  perform public.deal(r.code, rd.n);
  perform public.bump(r.code);
end
$$;

create or replace function public.give_clue(p_code text, p_clue text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
  v_clue text := left(regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g'), 80);
begin
  r := public.require_member(p_code);
  select * into rd from public.rounds where room = r.code and n = r.round;
  if rd.psychic <> auth.uid() or rd.phase <> 'clue' then
    raise exception 'It''s not your turn to give a clue';
  end if;
  if v_clue = '' then
    raise exception 'Type a clue';
  end if;
  update public.rounds set clue = v_clue, phase = 'guessing' where room = r.code and n = rd.n;
  perform public.bump(r.code);
end
$$;

create or replace function public.lock_guess(p_code text, p_value numeric)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
begin
  r := public.require_member(p_code);
  select * into rd from public.rounds where room = r.code and n = r.round;
  if r.status <> 'playing' or rd.phase <> 'guessing' then
    raise exception 'Not the time to guess';
  end if;
  if rd.psychic = auth.uid() then
    raise exception 'The psychic doesn''t guess';
  end if;
  insert into public.guesses (room, n, user_id, value) values (r.code, rd.n, auth.uid(), greatest(0, least(100, p_value)))
    on conflict (room, n, user_id) do nothing;
  -- Everyone in? Reveal.
  if not exists (
    select 1 from public.active_players(r.code) p
    where p.user_id <> rd.psychic
      and not exists (select 1 from public.guesses g where g.room = r.code and g.n = rd.n and g.user_id = p.user_id)
  ) then
    perform public.reveal(r.code);
  end if;
  perform public.bump(r.code);
end
$$;

-- When someone is taking too long: the host or the psychic can reveal anyway.
create or replace function public.force_reveal(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
begin
  r := public.require_member(p_code);
  select * into rd from public.rounds where room = r.code and n = r.round;
  if auth.uid() not in (r.host, rd.psychic) then
    raise exception 'Only the host or the psychic can reveal early';
  end if;
  perform public.reveal(r.code);
  perform public.bump(r.code);
end
$$;

-- Psychic left or went quiet before giving a clue: the host can skip the round.
create or replace function public.skip_round(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can skip a round';
  end if;
  update public.rounds set phase = 'reveal' where room = r.code and n = r.round and phase = 'clue';
  perform public.start_round(r.code);
  perform public.bump(r.code);
end
$$;

create or replace function public.next_round(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  if r.status <> 'playing' or not exists (select 1 from public.rounds where room = r.code and n = r.round and phase = 'reveal') then
    return;
  end if;
  perform public.start_round(r.code);
  perform public.bump(r.code);
end
$$;

create or replace function public.play_again(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
begin
  r := public.require_member(p_code);
  if r.host <> auth.uid() then
    raise exception 'Only the host can start a new game';
  end if;
  delete from public.rounds where room = r.code;
  update public.room_players set score = 0 where room = r.code;
  update public.rooms set status = 'lobby', round = 0, rounds_total = 0 where code = r.code;
  perform public.bump(r.code);
end
$$;

create or replace function public.heartbeat(p_code text)
returns void
language sql security definer set search_path = ''
as $$ update public.room_players set last_seen = now() where room = upper(p_code) and user_id = auth.uid() $$;

-- ---------------------------------------------------------------- state

-- Everything a player may see right now (secrets filtered out).
create or replace function public.get_room_state(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r public.rooms;
  rd public.rounds;
  v_me uuid := auth.uid();
  v_reveal boolean;
begin
  select * into r from public.rooms where code = upper(trim(coalesce(p_code, '')));
  if r.code is null then
    return jsonb_build_object('missing', true);
  end if;
  if not exists (select 1 from public.room_players where room = r.code and user_id = v_me and left_at is null) then
    return jsonb_build_object('code', r.code, 'joined', false, 'status', r.status);
  end if;
  select * into rd from public.rounds where room = r.code and n = r.round;
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
      from public.active_players(r.code) p), '[]'::jsonb),
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'left', c.left_label, 'right', c.right_label, 'mine', c.added_by = v_me) order by c.id)
      from public.room_cards c where c.room = r.code), '[]'::jsonb),
    'current', case when rd.room is null then null else jsonb_build_object(
      'n', rd.n,
      'psychic', rd.psychic,
      'left', rd.left_label,
      'right', rd.right_label,
      'clue', rd.clue,
      'phase', rd.phase,
      'skips', rd.skips,
      'target', case when v_reveal or rd.psychic = v_me then (select target from public.round_secrets s where s.room = r.code and s.n = rd.n) end,
      'guesses', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', g.user_id,
          'value', case when v_reveal or g.user_id = v_me then g.value end,
          'points', case when v_reveal then g.points end))
        from public.guesses g where g.room = r.code and g.n = rd.n), '[]'::jsonb)
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
    'create_room(text)', 'join_room(text, text)', 'leave_room(text)', 'update_settings(text, int, int)',
    'add_card(text, text, text)', 'remove_card(text, bigint)', 'start_game(text)', 'skip_card(text)',
    'give_clue(text, text)', 'lock_guess(text, numeric)', 'force_reveal(text)', 'skip_round(text)',
    'next_round(text)', 'play_again(text)', 'heartbeat(text)', 'get_room_state(text)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array[
    'is_room_member(text)', 'bump(text)', 'active_players(text)', 'require_member(text)', 'deal(text, int)',
    'start_round(text)', 'reveal(text)', 'points_for(numeric, numeric, numeric)', 'clean_name(text)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end
$$;
-- is_room_member is used by the room_ticks policy, so authenticated users need it.
grant execute on function public.is_room_member(text) to authenticated;
