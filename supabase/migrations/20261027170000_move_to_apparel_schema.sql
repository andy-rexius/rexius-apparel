-- ============================================================
-- Rexius Apparel Tracker — move everything from "public" into
-- the "apparel" schema and drop the "apparel_" prefix.
--
-- BEFORE running:
--   * "apparel" must be in Project Settings -> Data API ->
--     Exposed schemas (done).
--   * Deploy the updated admin-users Edge Function and push the
--     updated index.html right after this runs; until both are
--     out, the app will get "relation does not exist" errors.
--
-- The whole thing runs in ONE transaction: if any statement
-- fails, nothing changes. Data, indexes, foreign keys, check
-- constraints and sequences travel with the tables; nothing is
-- copied or re-inserted. Functions and policies are recreated
-- because their bodies name the old tables.
--
-- Result:
--   apparel.departments, apparel.employees, apparel.items,
--   apparel.app_users, apparel.transactions, apparel.inventory (view)
--   apparel.is_member(), is_admin(), my_role(), is_app_user()
--   apparel.auth_user_id_by_email(text), admin_list_users()   (service_role only)
--   apparel.tx_cost_handling()  + trigger on apparel.transactions
--   same 21 policies as before (members read; checkout users may add
--   employees and record checkouts; admins everything else)
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0. Sanity: refuse to run twice.
-- ------------------------------------------------------------
do $$
begin
  if to_regclass('public.apparel_items') is null then
    raise exception 'public.apparel_items not found - has this migration already run?';
  end if;
end $$;

create schema if not exists apparel;

-- ------------------------------------------------------------
-- 1. Drop policies (they call public.apparel_is_* functions)
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('apparel_items','apparel_departments','apparel_employees',
                        'apparel_transactions','apparel_app_users','apparel_inventory')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2. Drop the trigger and every public.apparel_* function
--    (bodies reference the old names; recreated below)
-- ------------------------------------------------------------
drop trigger  if exists apparel_tx_cost_handling on public.apparel_transactions;
drop function if exists public.apparel_tx_cost_handling();
drop function if exists public.apparel_is_member();
drop function if exists public.apparel_is_admin();
drop function if exists public.apparel_my_role();
drop function if exists public.apparel_is_app_user();
drop function if exists public.apparel_auth_user_id_by_email(text);
drop function if exists public.apparel_admin_list_users();
-- obsolete since user management moved to the Edge Function
drop function if exists public.apparel_add_app_user_by_email(text, text, text);
drop function if exists public.apparel_list_app_users();

-- ------------------------------------------------------------
-- 3. Move tables + view, then drop the prefix
-- ------------------------------------------------------------
alter table public.apparel_departments  set schema apparel;
alter table public.apparel_employees    set schema apparel;
alter table public.apparel_items        set schema apparel;
alter table public.apparel_app_users    set schema apparel;
alter table public.apparel_transactions set schema apparel;
alter view  public.apparel_inventory    set schema apparel;

alter table apparel.apparel_departments  rename to departments;
alter table apparel.apparel_employees    rename to employees;
alter table apparel.apparel_items        rename to items;
alter table apparel.apparel_app_users    rename to app_users;
alter table apparel.apparel_transactions rename to transactions;
alter view  apparel.apparel_inventory    rename to inventory;

-- cosmetic: tidy index / constraint names too
alter index apparel.apparel_tx_item_idx rename to tx_item_idx;
alter index apparel.apparel_tx_dept_idx rename to tx_dept_idx;
alter index apparel.apparel_tx_emp_idx  rename to tx_emp_idx;
alter index apparel.apparel_tx_time_idx rename to tx_time_idx;
alter table apparel.transactions rename constraint apparel_qty_sign to qty_sign;
alter table apparel.transactions rename constraint apparel_checkout_needs_dept_and_employee to checkout_needs_dept_and_employee;

-- ------------------------------------------------------------
-- 4. Helper functions, now in the apparel schema
-- ------------------------------------------------------------
create or replace function apparel.is_member()
returns boolean language sql stable security definer
set search_path = apparel, pg_temp
as $$
  select exists (select 1 from apparel.app_users where user_id = auth.uid() and active);
$$;

create or replace function apparel.is_admin()
returns boolean language sql stable security definer
set search_path = apparel, pg_temp
as $$
  select exists (select 1 from apparel.app_users where user_id = auth.uid() and active and role = 'admin');
$$;

create or replace function apparel.my_role()
returns text language sql stable security definer
set search_path = apparel, pg_temp
as $$
  select role from apparel.app_users where user_id = auth.uid() and active;
$$;

create or replace function apparel.is_app_user()
returns boolean language sql stable security definer
set search_path = apparel, pg_temp
as $$ select apparel.is_member(); $$;

revoke all on function apparel.is_member()   from public, anon;
revoke all on function apparel.is_admin()    from public, anon;
revoke all on function apparel.my_role()     from public, anon;
revoke all on function apparel.is_app_user() from public, anon;
grant execute on function
  apparel.is_member(), apparel.is_admin(), apparel.my_role(), apparel.is_app_user()
  to authenticated, service_role;

-- service-role-only helpers for the admin-users Edge Function
create or replace function apparel.auth_user_id_by_email(p_email text)
returns uuid language sql stable security definer
set search_path = apparel, pg_temp
as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
$$;

create or replace function apparel.admin_list_users()
returns table (
  user_id uuid, email text, display_name text, role text, active boolean,
  created_at timestamptz, last_sign_in_at timestamptz
)
language sql stable security definer
set search_path = apparel, pg_temp
as $$
  select u.user_id, a.email::text, u.display_name, u.role, u.active, u.created_at, a.last_sign_in_at
  from apparel.app_users u
  join auth.users a on a.id = u.user_id
  order by u.active desc, lower(coalesce(u.display_name, a.email));
$$;

revoke all on function apparel.auth_user_id_by_email(text) from public, anon, authenticated;
revoke all on function apparel.admin_list_users()          from public, anon, authenticated;
grant execute on function apparel.auth_user_id_by_email(text) to service_role;
grant execute on function apparel.admin_list_users()          to service_role;

-- ------------------------------------------------------------
-- 5. Cost-handling trigger
-- ------------------------------------------------------------
create or replace function apparel.tx_cost_handling()
returns trigger language plpgsql security definer
set search_path = apparel, pg_temp
as $$
begin
  if new.type = 'checkout' and new.unit_cost is null then
    select unit_cost into new.unit_cost from apparel.items where id = new.item_id;
  end if;
  if new.type = 'receive' and new.unit_cost is not null then
    update apparel.items set unit_cost = new.unit_cost where id = new.item_id;
  end if;
  return new;
end;
$$;

create trigger tx_cost_handling
before insert on apparel.transactions
for each row execute function apparel.tx_cost_handling();

-- ------------------------------------------------------------
-- 6. RLS + policies (same final state as the two earlier migrations)
-- ------------------------------------------------------------
alter table apparel.app_users    enable row level security;
alter table apparel.items        enable row level security;
alter table apparel.departments  enable row level security;
alter table apparel.employees    enable row level security;
alter table apparel.transactions enable row level security;
alter view  apparel.inventory    set (security_invoker = true);

-- items: members read, admins write
create policy "members_select" on apparel.items for select to authenticated using (apparel.is_member());
create policy "admins_insert"  on apparel.items for insert to authenticated with check (apparel.is_admin());
create policy "admins_update"  on apparel.items for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete"  on apparel.items for delete to authenticated using (apparel.is_admin());

-- departments: members read, admins write
create policy "members_select" on apparel.departments for select to authenticated using (apparel.is_member());
create policy "admins_insert"  on apparel.departments for insert to authenticated with check (apparel.is_admin());
create policy "admins_update"  on apparel.departments for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete"  on apparel.departments for delete to authenticated using (apparel.is_admin());

-- employees: members read + add, admins edit/delete
create policy "members_select" on apparel.employees for select to authenticated using (apparel.is_member());
create policy "members_insert" on apparel.employees for insert to authenticated with check (apparel.is_member());
create policy "admins_update"  on apparel.employees for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete"  on apparel.employees for delete to authenticated using (apparel.is_admin());

-- transactions: members read + record checkouts stamped with their own id; admins everything
create policy "members_select" on apparel.transactions for select to authenticated using (apparel.is_member());
create policy "members_insert" on apparel.transactions for insert to authenticated
  with check (apparel.is_member() and performed_by = auth.uid() and (type = 'checkout' or apparel.is_admin()));
create policy "admins_update"  on apparel.transactions for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete"  on apparel.transactions for delete to authenticated using (apparel.is_admin());

-- app_users: members read; anyone may read their own row; admins write, never their own row
create policy "members_select" on apparel.app_users for select to authenticated using (apparel.is_member());
create policy "self_select"    on apparel.app_users for select to authenticated using (user_id = auth.uid());
create policy "admins_insert"  on apparel.app_users for insert to authenticated with check (apparel.is_admin() and user_id <> auth.uid());
create policy "admins_update"  on apparel.app_users for update to authenticated
  using (apparel.is_admin() and user_id <> auth.uid()) with check (apparel.is_admin() and user_id <> auth.uid());
create policy "admins_delete"  on apparel.app_users for delete to authenticated using (apparel.is_admin() and user_id <> auth.uid());

-- ------------------------------------------------------------
-- 7. Grants. A custom schema gets NO automatic grants (unlike
--    public), so the API roles and the service role need them
--    explicitly, plus default privileges for tables added later.
-- ------------------------------------------------------------
grant usage on schema apparel to anon, authenticated, service_role;

revoke all on all tables in schema apparel from anon;
grant select, insert, update, delete on
  apparel.app_users, apparel.items, apparel.departments, apparel.employees, apparel.transactions
  to authenticated;
grant select on apparel.inventory to authenticated;

grant all on all tables    in schema apparel to service_role;
grant all on all sequences in schema apparel to service_role;

alter default privileges in schema apparel grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema apparel grant all on tables    to service_role;
alter default privileges in schema apparel grant all on sequences to service_role;

commit;

-- Tell PostgREST to reload its schema cache so the new schema is
-- visible immediately (it also picks it up on its own within a few
-- seconds; running this just removes the wait).
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- Checks (run separately after commit)
-- ------------------------------------------------------------
-- select table_name from information_schema.tables where table_schema = 'apparel' order by 1;
--   -> app_users, departments, employees, inventory, items, transactions
-- select tablename, policyname, cmd from pg_policies where schemaname = 'apparel' order by 1, 2;
--   -> 21 rows
-- select count(*) from apparel.transactions;   -- same count as before the move
-- select tablename from pg_tables where schemaname = 'public' and tablename like 'apparel_%';
--   -> 0 rows
