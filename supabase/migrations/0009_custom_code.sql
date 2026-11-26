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
