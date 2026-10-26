-- ============================================================
-- Rexius Apparel Tracker — Supabase schema
-- Everything lives in its own schema ("apparel") so it stays
-- isolated from the other app sharing this Supabase project.
-- Safe to run once in the Supabase SQL editor.
-- ============================================================

create schema if not exists apparel;

-- ------------------------------------------------------------
-- Reference tables
-- ------------------------------------------------------------

create table apparel.departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  code        text unique,                 -- optional short code for invoices
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table apparel.employees (
  id             uuid primary key default gen_random_uuid(),
  full_name      text not null,
  employee_no    text unique,              -- your internal employee ID
  department_id  uuid references apparel.departments(id),
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create table apparel.items (
  id                 uuid primary key default gen_random_uuid(),
  sku                text not null unique, -- encoded in the QR label, e.g. HV-VEST-C2-L
  name               text not null,       -- "Hi-Vis Class 2 Vest"
  category           text,                -- "vest", "shirt", "jacket", "hard hat"...
  size               text,                -- "L", "2XL", "OS"
  unit_cost          numeric(10,2) not null default 0,  -- most recent purchase cost
  reorder_threshold  integer not null default 0,        -- alert when on-hand <= this
  program            text not null default 'highvis',   -- 'highvis' now; 'annual' in phase 2
  active             boolean not null default true,
  created_at         timestamptz not null default now()
);

-- ------------------------------------------------------------
-- App users and roles (separate from the other app's users)
-- ------------------------------------------------------------

create table apparel.app_users (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  role          text not null check (role in ('checkout', 'admin')),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

-- Returns the current user's role, or null if they aren't an apparel user.
-- security definer so RLS policies can call it without recursion.
create or replace function apparel.my_role()
returns text
language sql
stable
security definer
set search_path = apparel, pg_temp
as $$
  select role from apparel.app_users
  where user_id = auth.uid() and active;
$$;

create or replace function apparel.is_admin()
returns boolean
language sql
stable
security definer
set search_path = apparel, pg_temp
as $$
  select coalesce(apparel.my_role() = 'admin', false);
$$;

create or replace function apparel.is_app_user()
returns boolean
language sql
stable
security definer
set search_path = apparel, pg_temp
as $$
  select apparel.my_role() is not null;
$$;

-- ------------------------------------------------------------
-- Transactions: the single source of truth for inventory
-- ------------------------------------------------------------

create table apparel.transactions (
  id             uuid primary key default gen_random_uuid(),
  type           text not null check (type in ('checkout', 'receive', 'adjust')),
  item_id        uuid not null references apparel.items(id),
  qty_change     integer not null,         -- signed: checkout < 0, receive > 0
  unit_cost      numeric(10,2),            -- cost snapshot at time of transaction
  department_id  uuid references apparel.departments(id),  -- required for checkouts
  employee_id    uuid references apparel.employees(id),    -- required for checkouts
  performed_by   uuid not null references auth.users(id),
  notes          text,
  created_at     timestamptz not null default now(),

  constraint qty_sign check (
    (type = 'checkout' and qty_change < 0) or
    (type = 'receive'  and qty_change > 0) or
    (type = 'adjust'   and qty_change <> 0)
  ),
  constraint checkout_needs_dept_and_employee check (
    type <> 'checkout' or (department_id is not null and employee_id is not null)
  )
);

create index on apparel.transactions (item_id);
create index on apparel.transactions (department_id, created_at);
create index on apparel.transactions (employee_id, created_at);
create index on apparel.transactions (created_at);

-- Checkouts snapshot the item's current cost if the app didn't supply one.
-- Receives with a cost update the item's current cost (latest purchase price).
create or replace function apparel.tx_cost_handling()
returns trigger
language plpgsql
security definer
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
-- Inventory view: on-hand and low-stock flags
-- ------------------------------------------------------------

create or replace view apparel.inventory
with (security_invoker = true)
as
select
  i.id,
  i.sku,
  i.name,
  i.category,
  i.size,
  i.unit_cost,
  i.reorder_threshold,
  i.program,
  i.active,
  coalesce(sum(t.qty_change), 0)::integer                    as on_hand,
  coalesce(sum(t.qty_change), 0) <= i.reorder_threshold      as low_stock
from apparel.items i
left join apparel.transactions t on t.item_id = i.id
group by i.id;

-- ------------------------------------------------------------
-- Row-level security
-- ------------------------------------------------------------

alter table apparel.departments  enable row level security;
alter table apparel.employees    enable row level security;
alter table apparel.items        enable row level security;
alter table apparel.app_users    enable row level security;
alter table apparel.transactions enable row level security;

-- Reference tables: any apparel user can read; admins manage.
create policy "app users read departments" on apparel.departments
  for select to authenticated using (apparel.is_app_user());
create policy "admins manage departments" on apparel.departments
  for all to authenticated using (apparel.is_admin()) with check (apparel.is_admin());

create policy "app users read employees" on apparel.employees
  for select to authenticated using (apparel.is_app_user());
create policy "admins manage employees" on apparel.employees
  for all to authenticated using (apparel.is_admin()) with check (apparel.is_admin());

create policy "app users read items" on apparel.items
  for select to authenticated using (apparel.is_app_user());
create policy "admins manage items" on apparel.items
  for all to authenticated using (apparel.is_admin()) with check (apparel.is_admin());

-- Users: read your own row; admins see and manage everyone.
create policy "read own app_user row" on apparel.app_users
  for select to authenticated using (user_id = auth.uid());
create policy "admins manage app_users" on apparel.app_users
  for all to authenticated using (apparel.is_admin()) with check (apparel.is_admin());

-- Transactions: app users read all and insert as themselves; admins edit/delete.
create policy "app users read transactions" on apparel.transactions
  for select to authenticated using (apparel.is_app_user());
create policy "app users insert transactions" on apparel.transactions
  for insert to authenticated
  with check (apparel.is_app_user() and performed_by = auth.uid());
create policy "admins update transactions" on apparel.transactions
  for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins delete transactions" on apparel.transactions
  for delete to authenticated using (apparel.is_admin());

-- ------------------------------------------------------------
-- Grants so the API role can reach the schema (RLS still applies)
-- ------------------------------------------------------------

grant usage on schema apparel to anon, authenticated;
grant select, insert, update, delete on all tables in schema apparel to authenticated;
grant select on apparel.inventory to authenticated;
grant execute on all functions in schema apparel to authenticated;
alter default privileges in schema apparel
  grant select, insert, update, delete on tables to authenticated;

-- ------------------------------------------------------------
-- AFTER RUNNING THIS SCRIPT
-- ------------------------------------------------------------
-- 1. Project Settings -> API -> "Exposed schemas": add  apparel
--    (keep public there too; the other app depends on it).
-- 2. Authentication -> Users -> create your own login if you don't
--    already have one, then make yourself the first admin:
--
--    insert into apparel.app_users (user_id, display_name, role)
--    values ('<your-auth-user-uuid>', 'Your Name', 'admin');
--
--    All other users can be added from the app's admin screen.
