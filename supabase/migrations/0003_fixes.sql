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
