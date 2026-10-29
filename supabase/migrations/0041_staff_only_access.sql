-- =============================================================================
-- 0041_staff_only_access.sql — only approved staff can use the shop's data
--                              (AceStock, foundation code review #1, #32)
--
-- Before: every new auth account got a 'staff' profile, every row-level
-- policy allowed any signed-in user, and the hosted projects allowed public
-- sign-up with no email confirmation. So anyone could create an account with
-- the public key and read customers, sales and gift cards or call the server
-- functions.
--
-- Now:
--   • New accounts start as 'pending', which has no access to anything except
--     its own profile row (so the app can say "waiting for approval").
--     Admins approve them (set_user_role → 'staff'), and can also remove an
--     account's access by setting it back to 'pending'.
--   • is_staff() — signed in AND role is staff or admin — replaces `true` in
--     every row-level policy. Admin-only policies keep is_admin().
--   • Server functions run with owner rights (0040), so row-level security
--     doesn't apply inside them. A statement-level trigger on every table
--     refuses writes by a signed-in account that isn't approved staff. That
--     covers every server function (and any added later) because each one
--     writes before it returns anything. Writes with no signed-in user
--     (migrations, the service role used by the create-staff Edge Function,
--     tests) are unaffected.
--   • set_user_role accepts 'pending' and locks the admin rows before the
--     last-admin check, so two admins can't demote each other at once (#32).
--
-- Staff accounts are now created by the admin-only create-staff Edge Function
-- (supabase/functions/create-staff); turn off public sign-up in each hosted
-- project (Authentication → Sign In / Providers).
--
-- Re-runnable.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Roles: 'pending' is the default and has no access.
-- ----------------------------------------------------------------------------
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles
  add constraint profiles_role_check check (role in ('admin', 'staff', 'pending'));
alter table profiles alter column role set default 'pending';

-- ----------------------------------------------------------------------------
-- 2. is_staff() / require_staff()
-- ----------------------------------------------------------------------------
create or replace function is_staff()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role in ('staff', 'admin')
  );
$$;

-- Raise unless the caller is approved staff. No signed-in user (owner,
-- service role, migrations) passes.
create or replace function require_staff()
returns void
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null and not is_staff() then
    raise exception 'This account hasn''t been approved for staff access yet'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function is_staff() from public, anon;
revoke all on function require_staff() from public, anon;
grant execute on function is_staff() to authenticated;
grant execute on function require_staff() to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Row-level policies: `true` becomes is_staff().
-- ----------------------------------------------------------------------------
do $$
declare
  pol record;
begin
  for pol in
    select tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
  loop
    if pol.qual = 'true' then
      execute format('alter policy %I on %I using (is_staff())', pol.policyname, pol.tablename);
    end if;
    if pol.with_check = 'true' then
      execute format('alter policy %I on %I with check (is_staff())', pol.policyname, pol.tablename);
    end if;
  end loop;
end $$;

-- A pending account can read only its own profile (to learn it's pending).
drop policy if exists profiles_authenticated_select on profiles;
create policy profiles_authenticated_select on profiles
  for select to authenticated
  using (is_staff() or id = auth.uid());

-- ----------------------------------------------------------------------------
-- 4. Writes by signed-in, non-staff accounts are refused on every table,
--    including writes made inside server functions.
-- ----------------------------------------------------------------------------
create or replace function enforce_staff_writer()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform require_staff();
  return null;  -- statement-level: the return value is ignored
end;
$$;

revoke all on function enforce_staff_writer() from public, anon, authenticated;

do $$
declare
  tbl text;
begin
  for tbl in select tablename from pg_tables where schemaname = 'public' loop
    execute format('drop trigger if exists trg_enforce_staff_writer on %I', tbl);
    execute format(
      'create trigger trg_enforce_staff_writer before insert or update or delete on %I '
      'for each statement execute function enforce_staff_writer()', tbl);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 5. set_user_role — same as 0028, plus 'pending' and a lock for the
--    last-admin check.
-- ----------------------------------------------------------------------------
create or replace function set_user_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_admin() then
    raise exception 'Only an admin can change roles';
  end if;
  if p_role not in ('admin', 'staff', 'pending') then
    raise exception 'Invalid role "%"', p_role;
  end if;
  if not exists (select 1 from profiles where id = p_user_id) then
    raise exception 'Unknown user %', p_user_id;
  end if;

  -- Lock every admin row first, so two admins demoting each other at the
  -- same moment are serialized and the second sees the first's change.
  perform 1 from profiles where role = 'admin' order by id for update;

  if p_role <> 'admin'
     and exists (select 1 from profiles where id = p_user_id and role = 'admin')
     and (select count(*) from profiles where role = 'admin') <= 1 then
    raise exception 'Cannot demote the last admin';
  end if;

  update profiles set role = p_role where id = p_user_id;
end;
$$;

revoke all on function set_user_role(uuid, text) from public, anon;
grant execute on function set_user_role(uuid, text) to authenticated;
