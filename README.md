# Rexius Apparel Tracker

Internal app for issuing branded high-vis apparel, tracking inventory, and generating department chargeback reports. Single HTML file on GitHub Pages, data in Supabase.

## Files

- `index.html` — the whole app. The Supabase URL and anon key are set at the top of the `<script>` block.
- `apparel_schema_public.sql` — creates the tables (prefixed `apparel_` in the `public` schema), inventory view, triggers, row-level security and admin helper functions. Run once.
- `later_move_to_own_schema.sql` — optional, for later: moves the tables into their own `apparel` schema once an admin exposes it.

## Supabase setup (one time)

1. SQL Editor → run `apparel_schema_public.sql`.
2. Nothing to expose: the tables live in `public`, which is already available to the API.
3. Authentication → Users → add your own login (email + password).
4. SQL Editor → make yourself the first admin:
   ```sql
   insert into public.apparel_app_users (user_id, display_name, role)
   values ('<your auth user UUID>', 'Your Name', 'admin');
   ```
   Every later user can be added from inside the app (Admin → Users) once they have a login.

## Deploy to GitHub Pages

1. Create a new repository (private is fine — Pages still works on private repos with GitHub Pro/Team/Enterprise; otherwise use a public repo).
2. Add `index.html` to the root of the repo and commit.
3. Repo → Settings → Pages → Source: "Deploy from a branch" → branch `main`, folder `/ (root)` → Save.
4. After a minute the site is live at `https://<org-or-user>.github.io/<repo>/`. Open it on a phone, sign in, and allow camera access when prompted.

The anon key is safe to publish: it only grants what the row-level security policies allow, and nothing is readable without an authenticated login that has been added to `apparel.app_users`.

## First-time data entry

In the app, Admin tab:

1. **Departments** — add each department that gets charged back.
2. **Items** — use "Add one item per size" for each product (e.g. name "Hi-Vis Class 2 Vest", prefix `HV-VEST-C2`, sizes `S, M, L, XL, 2XL, 3XL`). Set the unit cost and reorder threshold.
3. **Employees** — add names, employee numbers and home departments.
4. **Print labels** — print a QR label for each item (Avery 5160, 30 per sheet, print at 100% with no scaling).
5. **Receive** tab — enter your current stock on hand for each item so the counts start accurate.

## Day to day

- **Check out** — scan labels (or pick from the list), choose the employee, confirm the department, confirm. The employee's home department is preselected but can be changed.
- **Receive** — add incoming orders. Entering a unit cost updates the item's current cost, which future checkouts are charged at.
- **Inventory** — on-hand counts with low-stock items flagged first. Admins can adjust counts after a physical check and undo mistaken transactions.
- **Reports** — chargebacks by department for any date range, with CSV download.

## Later: annual apparel program

The `items.program` column already exists (`highvis` now). Phase 2 adds `annual` items, an allowance table per employee tier, and a balance check at checkout.
