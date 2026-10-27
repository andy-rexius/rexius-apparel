-- ============================================================
-- Rexius Apparel Tracker — tighten what the "checkout" role can do
--
-- Run AFTER 20261027120000_apparel_rls.sql, in the Supabase SQL editor.
-- Safe to re-run.
--
-- Checkout users (any active member who is not an admin) may now only:
--   * read everything they could before (needed for on-hand counts),
--   * add a new employee (from the checkout screen),
--   * record checkout transactions stamped with their own user id.
-- Everything else (receiving stock, count adjustments, undo, editing
-- items / departments / employees, user management) is admin-only.
-- The admin-users Edge Function is unaffected; no redeploy needed.
-- ============================================================

-- items: read-only for members -----------------------------------
drop policy if exists "apparel_members_insert" on public.apparel_items;
drop policy if exists "apparel_members_update" on public.apparel_items;
drop policy if exists "apparel_admins_insert"  on public.apparel_items;
drop policy if exists "apparel_admins_update"  on public.apparel_items;
create policy "apparel_admins_insert" on public.apparel_items
  for insert to authenticated with check (public.apparel_is_admin());
create policy "apparel_admins_update" on public.apparel_items
  for update to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

-- departments: read-only for members -----------------------------
drop policy if exists "apparel_members_insert" on public.apparel_departments;
drop policy if exists "apparel_members_update" on public.apparel_departments;
drop policy if exists "apparel_admins_insert"  on public.apparel_departments;
drop policy if exists "apparel_admins_update"  on public.apparel_departments;
create policy "apparel_admins_insert" on public.apparel_departments
  for insert to authenticated with check (public.apparel_is_admin());
create policy "apparel_admins_update" on public.apparel_departments
  for update to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

-- employees: members may ADD; only admins may edit/deactivate ------
drop policy if exists "apparel_members_insert" on public.apparel_employees;
drop policy if exists "apparel_members_update" on public.apparel_employees;
drop policy if exists "apparel_admins_update"  on public.apparel_employees;
create policy "apparel_members_insert" on public.apparel_employees
  for insert to authenticated with check (public.apparel_is_member());
create policy "apparel_admins_update" on public.apparel_employees
  for update to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

-- transactions: members may record CHECKOUTS only ------------------
-- (receive / adjust rows and any update are admin-only; delete was already)
drop policy if exists "apparel_members_insert" on public.apparel_transactions;
drop policy if exists "apparel_members_update" on public.apparel_transactions;
drop policy if exists "apparel_admins_update"  on public.apparel_transactions;
create policy "apparel_members_insert" on public.apparel_transactions
  for insert to authenticated
  with check (
    public.apparel_is_member()
    and performed_by = auth.uid()
    and (type = 'checkout' or public.apparel_is_admin())
  );
create policy "apparel_admins_update" on public.apparel_transactions
  for update to authenticated using (public.apparel_is_admin()) with check (public.apparel_is_admin());

-- Quick check (expect 21 rows, no "apparel_members_update" left except none):
--   select tablename, policyname, cmd from pg_policies
--   where tablename like 'apparel_%' order by 1, 2;
