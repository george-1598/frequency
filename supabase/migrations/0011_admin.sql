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
