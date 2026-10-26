-- ============================================================
-- Rexius Apparel Tracker — schema (public, prefixed)
-- All objects live in the "public" schema with an "apparel_"
-- prefix so they can't collide with the other app's tables.
-- Run once in the Supabase SQL editor. This replaces the
-- earlier apparel_schema.sql + addendum.
-- ============================================================

-- Remove the earlier separate-schema version (it held no data yet).
drop schema if exists apparel cascade;

-- ------------------------------------------------------------
-- Reference tables
-- ------------------------------------------------------------

create table public.apparel_departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  code        text unique,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.apparel_employees (
  id             uuid primary key default gen_random_uuid(),
  full_name      text not null,
  employee_no    text unique,
  department_id  uuid references public.apparel_departments(id),
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create table public.apparel_items (
  id                 uuid primary key default gen_random_uuid(),
  sku                text not null unique,
  name               text not null,
  category           text,
  size               text,
  unit_cost          numeric(10,2) not null default 0,
  reorder_threshold  integer not null default 0,
  program            text not null default 'highvis',
  active             boolean not null default true,
  created_at         timestamptz not null default now()
);

-- ------------------------------------------------------------
-- App users and roles
-- ------------------------------------------------------------

create table public.apparel_app_users (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  role          text not null check (role in ('checkout', 'admin')),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create or replace function public.apparel_my_role()
returns text language sql stable security definer
set search_path = public, pg_temp
as $$
  select role from public.apparel_app_users where user_id = auth.uid() and active;
$$;

create or replace function public.apparel_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$ select coalesce(public.apparel_my_role() = 'admin', false); $$;

create or replace function public.apparel_is_app_user()
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$ select public.apparel_my_role() is not null; $$;

-- ------------------------------------------------------------
-- Transactions
-- ------------------------------------------------------------

create table public.apparel_transactions (
  id             uuid primary key default gen_random_uuid(),
  type           text not null check (type in ('checkout', 'receive', 'adjust')),
  item_id        uuid not null references public.apparel_items(id),
  qty_change     integer not null,
  unit_cost      numeric(10,2),
  department_id  uuid references public.apparel_departments(id),
  employee_id    uuid references public.apparel_employees(id),
  performed_by   uuid not null references auth.users(id),
  notes          text,
  created_at     timestamptz not null default now(),

  constraint apparel_qty_sign check (
    (type = 'checkout' and qty_change < 0) or
    (type = 'receive'  and qty_change > 0) or
    (type = 'adjust'   and qty_change <> 0)
  ),
  constraint apparel_checkout_needs_dept_and_employee check (
    type <> 'checkout' or (department_id is not null and employee_id is not null)
  )
);

create index apparel_tx_item_idx on public.apparel_transactions (item_id);
create index apparel_tx_dept_idx on public.apparel_transactions (department_id, created_at);
create index apparel_tx_emp_idx  on public.apparel_transactions (employee_id, created_at);
create index apparel_tx_time_idx on public.apparel_transactions (created_at);

create or replace function public.apparel_tx_cost_handling()
returns trigger language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.type = 'checkout' and new.unit_cost is null then
    select unit_cost into new.unit_cost from public.apparel_items where id = new.item_id;
  end if;
  if new.type = 'receive' and new.unit_cost is not null then
    update public.apparel_items set unit_cost = new.unit_cost where id = new.item_id;
  end if;
  return new;
end;
$$;

create trigger apparel_tx_cost_handling
before insert on public.apparel_transactions
for each row execute function public.apparel_tx_cost_handling();

-- ------------------------------------------------------------
-- Inventory view
-- ------------------------------------------------------------

create or replace view public.apparel_inventory
with (security_invoker = true)
as
select
  i.id, i.sku, i.name, i.category, i.size, i.unit_cost, i.reorder_threshold, i.program, i.active,
  coalesce(sum(t.qty_change), 0)::integer               as on_hand,
  coalesce(sum(t.qty_change), 0) <= i.reorder_threshold as low_stock
from public.apparel_items i
left join public.apparel_transactions t on t.item_id = i.id
group by i.id;

-- ------------------------------------------------------------
-- Row-level security
-- ------------------------------------------------------------

alter table public.apparel_departments  enable row level security;
alter table public.apparel_employees    enable row level security;
alter table public.apparel_items        enable row level security;
alter table public.apparel_app_users    enable row level security;
alter table public.apparel_transactions enable row level security;

create policy "apparel users read departments" on public.apparel_departments
  for select to authenticated using (public.apparel_is_app_user());
create policy "apparel admins manage departments" on public.apparel_departments
  for all to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

create policy "apparel users read employees" on public.apparel_employees
  for select to authenticated using (public.apparel_is_app_user());
create policy "apparel admins manage employees" on public.apparel_employees
  for all to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

create policy "apparel users read items" on public.apparel_items
  for select to authenticated using (public.apparel_is_app_user());
create policy "apparel admins manage items" on public.apparel_items
  for all to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

create policy "apparel read own user row" on public.apparel_app_users
  for select to authenticated using (user_id = auth.uid());
create policy "apparel admins manage users" on public.apparel_app_users
  for all to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

create policy "apparel users read transactions" on public.apparel_transactions
  for select to authenticated using (public.apparel_is_app_user());
create policy "apparel users insert transactions" on public.apparel_transactions
  for insert to authenticated
  with check (public.apparel_is_app_user() and performed_by = auth.uid());
create policy "apparel admins update transactions" on public.apparel_transactions
  for update to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());
create policy "apparel admins delete transactions" on public.apparel_transactions
  for delete to authenticated using (public.apparel_is_admin());

-- ------------------------------------------------------------
-- Admin helpers used by the Users screen
-- ------------------------------------------------------------

create or replace function public.apparel_add_app_user_by_email(p_email text, p_display_name text, p_role text)
returns void language plpgsql security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid;
begin
  if not public.apparel_is_admin() then raise exception 'Only admins can add users.'; end if;
  if p_role not in ('checkout', 'admin') then raise exception 'Role must be checkout or admin.'; end if;
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if v_id is null then
    raise exception 'No login found for %. Create it under Authentication -> Users first, then try again.', p_email;
  end if;
  insert into public.apparel_app_users (user_id, display_name, role)
  values (v_id, p_display_name, p_role)
  on conflict (user_id) do update
    set display_name = excluded.display_name, role = excluded.role, active = true;
end;
$$;

create or replace function public.apparel_list_app_users()
returns table (user_id uuid, email text, display_name text, role text, active boolean, created_at timestamptz)
language sql stable security definer
set search_path = public, auth, pg_temp
as $$
  select u.user_id, a.email, u.display_name, u.role, u.active, u.created_at
  from public.apparel_app_users u
  join auth.users a on a.id = u.user_id
  where public.apparel_is_admin()
  order by u.display_name;
$$;

-- ------------------------------------------------------------
-- Grants (RLS still applies)
-- ------------------------------------------------------------

grant select, insert, update, delete on
  public.apparel_departments, public.apparel_employees, public.apparel_items,
  public.apparel_app_users, public.apparel_transactions to authenticated;
grant select on public.apparel_inventory to authenticated;
grant execute on function
  public.apparel_my_role(), public.apparel_is_admin(), public.apparel_is_app_user(),
  public.apparel_add_app_user_by_email(text, text, text), public.apparel_list_app_users()
  to authenticated;

-- ------------------------------------------------------------
-- AFTER RUNNING: make yourself the first admin
-- (Authentication -> Users -> click your user -> copy the UUID)
-- ------------------------------------------------------------
--
--   insert into public.apparel_app_users (user_id, display_name, role)
--   values ('<your-auth-user-uuid>', 'Your Name', 'admin');
