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
