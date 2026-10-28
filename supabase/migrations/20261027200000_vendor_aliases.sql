-- ============================================================
-- Vendor line matches ("aliases").
--
-- When an invoice is read automatically, each vendor line has to
-- be matched to one of our items. The first time, a person picks
-- the item on the review screen; that choice is saved here so the
-- next invoice from the same vendor matches the line on its own.
--
-- A line is keyed by the vendor's SKU / part number when the
-- invoice shows one, otherwise by its description. Both keys are
-- stored normalized (lower-case, single spaces) in *_key columns
-- so the lookup is a plain equality and upserts can target the
-- unique constraint.
--
-- Admin-only, like invoices. Safe to re-run.
-- ============================================================

begin;

create table if not exists apparel.vendor_aliases (
  id           uuid primary key default gen_random_uuid(),
  vendor       text not null,                 -- as shown on the invoice
  vendor_key   text not null,                 -- normalized vendor
  vendor_sku   text,                          -- vendor's SKU / part no., if any
  description  text,                          -- vendor's line description
  alias_key    text not null,                 -- normalized sku, else normalized description
  item_id      uuid not null references apparel.items(id) on delete cascade,
  uses         integer not null default 1,    -- how many lines this match has received
  created_by   uuid not null references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint vendor_aliases_unique unique (vendor_key, alias_key)
);
create index if not exists vendor_aliases_item_idx on apparel.vendor_aliases (item_id);

alter table apparel.vendor_aliases enable row level security;

drop policy if exists "admins_select" on apparel.vendor_aliases;
drop policy if exists "admins_insert" on apparel.vendor_aliases;
drop policy if exists "admins_update" on apparel.vendor_aliases;
drop policy if exists "admins_delete" on apparel.vendor_aliases;
create policy "admins_select" on apparel.vendor_aliases for select to authenticated using (apparel.is_admin());
create policy "admins_insert" on apparel.vendor_aliases for insert to authenticated with check (apparel.is_admin());
create policy "admins_update" on apparel.vendor_aliases for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete" on apparel.vendor_aliases for delete to authenticated using (apparel.is_admin());

grant select, insert, update, delete on apparel.vendor_aliases to authenticated;
grant all on apparel.vendor_aliases to service_role;

commit;

notify pgrst, 'reload schema';
