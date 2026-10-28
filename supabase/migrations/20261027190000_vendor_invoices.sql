-- ============================================================
-- Vendor invoices: a private Storage bucket for the scans/PDFs,
-- an apparel.invoices table for the metadata, and a link from
-- each "receive" transaction to the invoice it came from.
--
-- Everything here is admin-only (same people who can receive
-- stock). Checkout users never see cost documents.
--
-- Safe to re-run: every statement is "if not exists" / "or
-- replace" / drop-then-create.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Metadata table
-- ------------------------------------------------------------
create table if not exists apparel.invoices (
  id            uuid primary key default gen_random_uuid(),
  vendor        text not null,
  invoice_no    text,
  invoice_date  date,
  total         numeric(10,2),
  notes         text,
  file_path     text not null unique,     -- object key inside the bucket
  file_name     text not null,            -- original name, for display/download
  content_type  text,
  size_bytes    bigint,
  uploaded_by   uuid not null references auth.users(id),
  created_at    timestamptz not null default now()
);
create index if not exists invoices_vendor_idx       on apparel.invoices (lower(vendor));
create index if not exists invoices_invoice_date_idx on apparel.invoices (invoice_date desc);

alter table apparel.invoices enable row level security;

drop policy if exists "admins_select" on apparel.invoices;
drop policy if exists "admins_insert" on apparel.invoices;
drop policy if exists "admins_update" on apparel.invoices;
drop policy if exists "admins_delete" on apparel.invoices;
create policy "admins_select" on apparel.invoices for select to authenticated using (apparel.is_admin());
create policy "admins_insert" on apparel.invoices for insert to authenticated with check (apparel.is_admin() and uploaded_by = auth.uid());
create policy "admins_update" on apparel.invoices for update to authenticated using (apparel.is_admin()) with check (apparel.is_admin());
create policy "admins_delete" on apparel.invoices for delete to authenticated using (apparel.is_admin());

grant select, insert, update, delete on apparel.invoices to authenticated;
grant all on apparel.invoices to service_role;

-- ------------------------------------------------------------
-- 2. Link receive lines to their invoice
-- ------------------------------------------------------------
alter table apparel.transactions
  add column if not exists invoice_id uuid references apparel.invoices(id) on delete set null;
create index if not exists transactions_invoice_id_idx on apparel.transactions (invoice_id);

-- ------------------------------------------------------------
-- 3. Storage bucket (private; files are fetched via signed URLs)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'apparel-invoices', 'apparel-invoices', false,
  26214400,                                   -- 25 MB per file
  array['application/pdf','image/jpeg','image/png','image/heic','image/heif','image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- storage.objects is shared by every bucket in the project, so the
-- policies are scoped to this bucket and prefixed to avoid clashing
-- with the other app's policies.
drop policy if exists "apparel_invoices_admins_select" on storage.objects;
drop policy if exists "apparel_invoices_admins_insert" on storage.objects;
drop policy if exists "apparel_invoices_admins_update" on storage.objects;
drop policy if exists "apparel_invoices_admins_delete" on storage.objects;
create policy "apparel_invoices_admins_select" on storage.objects for select to authenticated
  using (bucket_id = 'apparel-invoices' and apparel.is_admin());
create policy "apparel_invoices_admins_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'apparel-invoices' and apparel.is_admin());
create policy "apparel_invoices_admins_update" on storage.objects for update to authenticated
  using (bucket_id = 'apparel-invoices' and apparel.is_admin())
  with check (bucket_id = 'apparel-invoices' and apparel.is_admin());
create policy "apparel_invoices_admins_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'apparel-invoices' and apparel.is_admin());

commit;

notify pgrst, 'reload schema';

-- Checks (run separately after commit):
-- select id, public, file_size_limit from storage.buckets where id = 'apparel-invoices';
-- select policyname from pg_policies where tablename = 'objects' and policyname like 'apparel_invoices%';
