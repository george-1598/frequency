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
