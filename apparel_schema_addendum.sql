-- ============================================================
-- Rexius Apparel Tracker — addendum
-- Lets admins add app users from inside the app by email,
-- instead of pasting UUIDs. Run once in the SQL editor.
-- ============================================================

create or replace function apparel.add_app_user_by_email(
  p_email text,
  p_display_name text,
  p_role text
)
returns void
language plpgsql
security definer
set search_path = apparel, auth, pg_temp
as $$
declare
  v_id uuid;
begin
  if not apparel.is_admin() then
    raise exception 'Only admins can add users.';
  end if;

  if p_role not in ('checkout', 'admin') then
    raise exception 'Role must be checkout or admin.';
  end if;

  select id into v_id from auth.users where lower(email) = lower(p_email);

  if v_id is null then
    raise exception 'No login found for %. Create it under Authentication -> Users first, then try again.', p_email;
  end if;

  insert into apparel.app_users (user_id, display_name, role)
  values (v_id, p_display_name, p_role)
  on conflict (user_id) do update
    set display_name = excluded.display_name,
        role = excluded.role,
        active = true;
end;
$$;

grant execute on function apparel.add_app_user_by_email(text, text, text) to authenticated;

-- Lets the app show each user's email next to their name on the Users screen.
create or replace function apparel.list_app_users()
returns table (user_id uuid, email text, display_name text, role text, active boolean, created_at timestamptz)
language sql
stable
security definer
set search_path = apparel, auth, pg_temp
as $$
  select u.user_id, a.email, u.display_name, u.role, u.active, u.created_at
  from apparel.app_users u
  join auth.users a on a.id = u.user_id
  where apparel.is_admin()
  order by u.display_name;
$$;

grant execute on function apparel.list_app_users() to authenticated;
