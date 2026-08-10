-- =============================================================================
-- 0028_profiles_roles.sql — account roles (admin / staff) (AceStock)
--
-- Each auth user gets a profile with a role. Admins reach admin-only screens
-- (Categories, Settings, user management); staff run the register and service
-- flows. Access is gated in the UI; roles are managed in-app by admins via
-- set_user_role (which is admin-guarded so staff can't self-promote).
--
-- Re-runnable.
-- =============================================================================

create table if not exists profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text,
  role       text not null default 'staff' check (role in ('admin', 'staff')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;
drop policy if exists profiles_authenticated_select on profiles;
create policy profiles_authenticated_select on profiles for select to authenticated using (true);
grant select on profiles to authenticated;

-- Create a profile automatically when an auth user is created.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_auth_user_created on auth.users;
create trigger trg_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Backfill profiles for any users that already exist.
insert into profiles (id, email)
select id, email from auth.users
on conflict (id) do nothing;

-- is_admin — is the current user an admin? SECURITY DEFINER so it reads profiles
-- regardless of RLS (and avoids recursive policy evaluation).
create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;
grant execute on function is_admin() to authenticated;

-- set_user_role — admin-only role change, guarded so the last admin can't be
-- demoted (which would lock everyone out of admin screens).
create or replace function set_user_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Only an admin can change roles';
  end if;
  if p_role not in ('admin', 'staff') then
    raise exception 'Invalid role "%"', p_role;
  end if;
  if not exists (select 1 from profiles where id = p_user_id) then
    raise exception 'Unknown user %', p_user_id;
  end if;
  if p_role = 'staff'
     and exists (select 1 from profiles where id = p_user_id and role = 'admin')
     and (select count(*) from profiles where role = 'admin') <= 1 then
    raise exception 'Cannot demote the last admin';
  end if;
  update profiles set role = p_role where id = p_user_id;
end;
$$;
grant execute on function set_user_role(uuid, text) to authenticated;
