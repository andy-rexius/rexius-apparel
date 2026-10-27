-- ============================================================
-- LATER: move the apparel tables out of "public" into their
-- own "apparel" schema. Not needed today. Run only after an
-- admin has added "apparel" to Project Settings -> API ->
-- Exposed schemas, and plan to update index.html at the same
-- time (schema option + table/function names lose the prefix).
-- Data, indexes, foreign keys and RLS policies move with the
-- tables; nothing is copied or lost.
-- ============================================================

create schema if not exists apparel;

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

-- Functions reference the old names in their bodies, so recreate them
-- rather than moving them: re-run the function definitions from
-- apparel_schema.sql (the original separate-schema version), then:
drop function if exists public.apparel_my_role();
drop function if exists public.apparel_is_admin();
drop function if exists public.apparel_is_app_user();
drop function if exists public.apparel_add_app_user_by_email(text, text, text);
drop function if exists public.apparel_list_app_users();
drop function if exists public.apparel_tx_cost_handling() cascade;

grant usage on schema apparel to anon, authenticated;
grant select, insert, update, delete on all tables in schema apparel to authenticated;
grant execute on all functions in schema apparel to authenticated;
