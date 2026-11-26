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
