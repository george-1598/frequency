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
