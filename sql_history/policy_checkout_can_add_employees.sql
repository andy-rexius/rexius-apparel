-- Lets any apparel user (checkout or admin) add a new employee from the
-- checkout screen. They still can't edit, deactivate or delete employees;
-- that stays admin-only. Run once in the Supabase SQL editor.

create policy "apparel users add employees" on public.apparel_employees
  for insert to authenticated
  with check (public.apparel_is_app_user());
