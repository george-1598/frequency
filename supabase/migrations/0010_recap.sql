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
