-- ============================================================
-- Rexius Apparel Tracker — row-level security + admin helpers
--
-- This Supabase project is SHARED with the applicant-tracker app, so
-- every apparel_* table is locked down to rows in apparel_app_users
-- (not merely to any signed-in user). Safe to re-run: every object is
-- created with "or replace" / "if exists" guards.
--
-- Run in the Supabase SQL editor (Developers can run SQL even though
-- they can't change project settings).
--
-- Summary of access:
--   members (active row in apparel_app_users, any role)
--     SELECT  on all six apparel objects
--     INSERT/UPDATE on items, inventory, departments, employees, transactions
--   admins (active row with role = 'admin')
--     everything members can do, plus DELETE on those tables, and
--     INSERT/UPDATE/DELETE on apparel_app_users (never on their own row)
--   anon / non-members: nothing
-- ============================================================

-- ------------------------------------------------------------
-- 1. Helper functions
--    SECURITY DEFINER so they run as the table owner and bypass RLS
--    on apparel_app_users (otherwise a policy that reads
--    apparel_app_users would recurse into itself). search_path is
--    pinned so a malicious schema can't shadow the table name.
-- ------------------------------------------------------------

create or replace function public.apparel_is_member()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.apparel_app_users
    where user_id = auth.uid() and active
  );
$$;

create or replace function public.apparel_is_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.apparel_app_users
    where user_id = auth.uid() and active and role = 'admin'
  );
$$;

-- Older names used by earlier SQL files / policies; keep them working.
create or replace function public.apparel_my_role()
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select role from public.apparel_app_users where user_id = auth.uid() and active;
$$;

create or replace function public.apparel_is_app_user()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select public.apparel_is_member(); $$;

revoke all on function public.apparel_is_member()   from public, anon;
revoke all on function public.apparel_is_admin()    from public, anon;
revoke all on function public.apparel_my_role()     from public, anon;
revoke all on function public.apparel_is_app_user() from public, anon;
grant execute on function
  public.apparel_is_member(), public.apparel_is_admin(),
  public.apparel_my_role(), public.apparel_is_app_user()
  to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. Service-role-only helpers used by the admin-users Edge Function.
--    auth.users is not exposed through the REST API, so the function
--    reaches it through these. Nothing here is callable by browsers:
--    EXECUTE is granted to service_role only.
-- ------------------------------------------------------------

-- Look up an auth user id by email (case-insensitive). Used when an
-- admin adds someone who already has a login from the other app.
create or replace function public.apparel_auth_user_id_by_email(p_email text)
returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
$$;

-- apparel_app_users joined with email + last sign-in from auth.users.
create or replace function public.apparel_admin_list_users()
returns table (
  user_id uuid, email text, display_name text, role text, active boolean,
  created_at timestamptz, last_sign_in_at timestamptz
)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select u.user_id, a.email::text, u.display_name, u.role, u.active, u.created_at, a.last_sign_in_at
  from public.apparel_app_users u
  join auth.users a on a.id = u.user_id
  order by u.active desc, lower(coalesce(u.display_name, a.email));
$$;

revoke all on function public.apparel_auth_user_id_by_email(text) from public, anon, authenticated;
revoke all on function public.apparel_admin_list_users()          from public, anon, authenticated;
grant execute on function public.apparel_auth_user_id_by_email(text) to service_role;
grant execute on function public.apparel_admin_list_users()          to service_role;

-- ------------------------------------------------------------
-- 3. Enable RLS on the six apparel objects.
--    apparel_inventory is a VIEW in the current schema (an aggregate
--    over items + transactions). Views can't carry RLS themselves;
--    with security_invoker = true the policies on the underlying
--    tables apply to whoever queries the view. The block below handles
--    either shape so this file keeps working if it ever becomes a table.
-- ------------------------------------------------------------

alter table public.apparel_app_users    enable row level security;
alter table public.apparel_items        enable row level security;
alter table public.apparel_departments  enable row level security;
alter table public.apparel_employees    enable row level security;
alter table public.apparel_transactions enable row level security;

do $$
declare v_kind char;
begin
  select c.relkind into v_kind
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'apparel_inventory';

  if v_kind in ('r', 'p') then
    execute 'alter table public.apparel_inventory enable row level security';
  elsif v_kind = 'v' then
    execute 'alter view public.apparel_inventory set (security_invoker = true)';
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. Policies. Drop the earlier admin-centric set (and any previous
--    run of this file) first so the result is exactly what's below.
-- ------------------------------------------------------------

-- earlier names from apparel_schema_public.sql / policy_checkout_can_add_employees.sql
drop policy if exists "apparel users read departments"      on public.apparel_departments;
drop policy if exists "apparel admins manage departments"   on public.apparel_departments;
drop policy if exists "apparel users read employees"        on public.apparel_employees;
drop policy if exists "apparel admins manage employees"     on public.apparel_employees;
drop policy if exists "apparel users add employees"         on public.apparel_employees;
drop policy if exists "apparel users read items"            on public.apparel_items;
drop policy if exists "apparel admins manage items"         on public.apparel_items;
drop policy if exists "apparel read own user row"           on public.apparel_app_users;
drop policy if exists "apparel admins manage users"         on public.apparel_app_users;
drop policy if exists "apparel users read transactions"     on public.apparel_transactions;
drop policy if exists "apparel users insert transactions"   on public.apparel_transactions;
drop policy if exists "apparel admins update transactions"  on public.apparel_transactions;
drop policy if exists "apparel admins delete transactions"  on public.apparel_transactions;

-- names used below
drop policy if exists "apparel_members_select"  on public.apparel_items;
drop policy if exists "apparel_members_insert"  on public.apparel_items;
drop policy if exists "apparel_members_update"  on public.apparel_items;
drop policy if exists "apparel_admins_delete"   on public.apparel_items;
drop policy if exists "apparel_members_select"  on public.apparel_departments;
drop policy if exists "apparel_members_insert"  on public.apparel_departments;
drop policy if exists "apparel_members_update"  on public.apparel_departments;
drop policy if exists "apparel_admins_delete"   on public.apparel_departments;
drop policy if exists "apparel_members_select"  on public.apparel_employees;
drop policy if exists "apparel_members_insert"  on public.apparel_employees;
drop policy if exists "apparel_members_update"  on public.apparel_employees;
drop policy if exists "apparel_admins_delete"   on public.apparel_employees;
drop policy if exists "apparel_members_select"  on public.apparel_transactions;
drop policy if exists "apparel_members_insert"  on public.apparel_transactions;
drop policy if exists "apparel_members_update"  on public.apparel_transactions;
drop policy if exists "apparel_admins_delete"   on public.apparel_transactions;
drop policy if exists "apparel_members_select"  on public.apparel_app_users;
drop policy if exists "apparel_self_select"     on public.apparel_app_users;
drop policy if exists "apparel_admins_insert"   on public.apparel_app_users;
drop policy if exists "apparel_admins_update"   on public.apparel_app_users;
drop policy if exists "apparel_admins_delete"   on public.apparel_app_users;

-- items ------------------------------------------------------
create policy "apparel_members_select" on public.apparel_items
  for select to authenticated using (public.apparel_is_member());
create policy "apparel_members_insert" on public.apparel_items
  for insert to authenticated with check (public.apparel_is_member());
create policy "apparel_members_update" on public.apparel_items
  for update to authenticated using (public.apparel_is_member()) with check (public.apparel_is_member());
create policy "apparel_admins_delete" on public.apparel_items
  for delete to authenticated using (public.apparel_is_admin());

-- departments ------------------------------------------------
create policy "apparel_members_select" on public.apparel_departments
  for select to authenticated using (public.apparel_is_member());
create policy "apparel_members_insert" on public.apparel_departments
  for insert to authenticated with check (public.apparel_is_member());
create policy "apparel_members_update" on public.apparel_departments
  for update to authenticated using (public.apparel_is_member()) with check (public.apparel_is_member());
create policy "apparel_admins_delete" on public.apparel_departments
  for delete to authenticated using (public.apparel_is_admin());

-- employees --------------------------------------------------
create policy "apparel_members_select" on public.apparel_employees
  for select to authenticated using (public.apparel_is_member());
create policy "apparel_members_insert" on public.apparel_employees
  for insert to authenticated with check (public.apparel_is_member());
create policy "apparel_members_update" on public.apparel_employees
  for update to authenticated using (public.apparel_is_member()) with check (public.apparel_is_member());
create policy "apparel_admins_delete" on public.apparel_employees
  for delete to authenticated using (public.apparel_is_admin());

-- transactions -----------------------------------------------
-- Inserts must be stamped with the caller's own id so "performed_by"
-- in the activity log can't be forged.
create policy "apparel_members_select" on public.apparel_transactions
  for select to authenticated using (public.apparel_is_member());
create policy "apparel_members_insert" on public.apparel_transactions
  for insert to authenticated with check (public.apparel_is_member() and performed_by = auth.uid());
create policy "apparel_members_update" on public.apparel_transactions
  for update to authenticated using (public.apparel_is_member()) with check (public.apparel_is_member());
create policy "apparel_admins_delete" on public.apparel_transactions
  for delete to authenticated using (public.apparel_is_admin());

-- apparel_inventory (only if it is a real table; see section 3) ----
do $$
begin
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'apparel_inventory' and c.relkind in ('r', 'p')
  ) then
    execute 'drop policy if exists "apparel_members_select" on public.apparel_inventory';
    execute 'drop policy if exists "apparel_members_insert" on public.apparel_inventory';
    execute 'drop policy if exists "apparel_members_update" on public.apparel_inventory';
    execute 'drop policy if exists "apparel_admins_delete"  on public.apparel_inventory';
    execute 'create policy "apparel_members_select" on public.apparel_inventory for select to authenticated using (public.apparel_is_member())';
    execute 'create policy "apparel_members_insert" on public.apparel_inventory for insert to authenticated with check (public.apparel_is_member())';
    execute 'create policy "apparel_members_update" on public.apparel_inventory for update to authenticated using (public.apparel_is_member()) with check (public.apparel_is_member())';
    execute 'create policy "apparel_admins_delete"  on public.apparel_inventory for delete to authenticated using (public.apparel_is_admin())';
  end if;
end $$;

-- apparel_app_users ------------------------------------------
-- Readable by members. A signed-in user may also read their OWN row
-- even when inactive, which is how the app tells "not set up yet /
-- deactivated" apart from a database error at sign-in. Writes are
-- admin-only and never allowed on the admin's own row, so nobody can
-- promote, demote, or deactivate themselves from the browser.
create policy "apparel_members_select" on public.apparel_app_users
  for select to authenticated using (public.apparel_is_member());
create policy "apparel_self_select" on public.apparel_app_users
  for select to authenticated using (user_id = auth.uid());
create policy "apparel_admins_insert" on public.apparel_app_users
  for insert to authenticated with check (public.apparel_is_admin() and user_id <> auth.uid());
create policy "apparel_admins_update" on public.apparel_app_users
  for update to authenticated
  using (public.apparel_is_admin() and user_id <> auth.uid())
  with check (public.apparel_is_admin() and user_id <> auth.uid());
create policy "apparel_admins_delete" on public.apparel_app_users
  for delete to authenticated using (public.apparel_is_admin() and user_id <> auth.uid());

-- ------------------------------------------------------------
-- 5. Table grants. RLS still applies on top of these. anon gets nothing.
-- ------------------------------------------------------------

revoke all on
  public.apparel_app_users, public.apparel_items, public.apparel_departments,
  public.apparel_employees, public.apparel_transactions, public.apparel_inventory
  from anon;
grant select, insert, update, delete on
  public.apparel_app_users, public.apparel_items, public.apparel_departments,
  public.apparel_employees, public.apparel_transactions
  to authenticated;
grant select on public.apparel_inventory to authenticated;

-- ------------------------------------------------------------
-- 6. Bootstrap the first admin (run ONCE, after the person has a login
--    under Authentication -> Users). Uncomment, edit the email and
--    name, and run. Safe to re-run: it just re-asserts admin + active.
-- ------------------------------------------------------------
--
-- insert into public.apparel_app_users (user_id, display_name, role, active)
-- select id, 'Your Name', 'admin', true
-- from auth.users where lower(email) = lower('you@rexius.com')
-- on conflict (user_id) do update set role = 'admin', active = true;
