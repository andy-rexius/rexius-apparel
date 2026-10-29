// Rexius Apparel — admin-users Edge Function
//
// Lets an ACTIVE ADMIN (role = 'admin' in apparel.app_users) manage
// the apparel app's users from the browser without ever exposing the
// service-role key to the page.
//
// Request:  POST /functions/v1/admin-users
//           Authorization: Bearer <caller's Supabase access token>
//           apikey: <anon key>
//           body: { "action": "...", ...fields }
//
// Actions:
//   list                                   -> { users: [...] }
//   create  { email, password, role, display_name? }
//   set_role        { user_id, role }
//   set_display_name{ user_id, display_name }
//   reset_password  { user_id, password }
//   deactivate      { user_id }
//   reactivate      { user_id }
//
// Every response is JSON. Errors look like { "error": "message" } with a
// 4xx/5xx status. Nothing is hardcoded: SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are injected by Supabase at deploy time.
//
// Deployed with gateway JWT verification OFF (supabase/config.toml) so the
// browser's CORS preflight gets through; the function verifies the JWT
// itself below, then checks the caller is an active admin.

import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.45.4";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// The GitHub Pages origin the app is served from. Extra origins (for local
// testing) can be added as a comma-separated list in the optional
// APPAREL_EXTRA_ORIGINS secret, e.g. "http://localhost:5500,http://127.0.0.1:5500".
const ALLOWED_ORIGINS = new Set<string>([
  "https://rexiusfleet.github.io",
  ...(Deno.env.get("APPAREL_EXTRA_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
]);

const ROLES = ["checkout", "admin"] as const;
type Role = (typeof ROLES)[number];
const MIN_PASSWORD_LENGTH = 8;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json; charset=utf-8" },
  });
}

function str(v: unknown, field: string, { required = true, max = 200 } = {}): string {
  if (v === undefined || v === null || v === "") {
    if (required) throw new HttpError(400, `${field} is required.`);
    return "";
  }
  if (typeof v !== "string") throw new HttpError(400, `${field} must be a string.`);
  const s = v.trim();
  if (s.length > max) throw new HttpError(400, `${field} is too long.`);
  return s;
}

function parseEmail(v: unknown): string {
  const email = str(v, "email").toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new HttpError(400, "That doesn't look like a valid email address.");
  return email;
}

function parseRole(v: unknown): Role {
  const role = str(v, "role");
  if (!(ROLES as readonly string[]).includes(role)) throw new HttpError(400, `role must be one of: ${ROLES.join(", ")}.`);
  return role as Role;
}

function parsePassword(v: unknown): string {
  if (typeof v !== "string" || !v) throw new HttpError(400, "password is required.");
  if (v.length < MIN_PASSWORD_LENGTH) throw new HttpError(400, `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`);
  if (v.length > 72) throw new HttpError(400, "Password is too long (max 72 characters).");
  return v;
}

function parseUserId(v: unknown): string {
  const id = str(v, "user_id");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new HttpError(400, "user_id must be a UUID.");
  return id;
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

const noSession = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
// The service-role client talks to the "apparel" schema (tables live there, not in public).
const adminOpts = { ...noSession, db: { schema: "apparel" } };

/** Verifies the caller's access token with the anon client and returns the auth user. */
async function requireCaller(req: Request): Promise<User> {
  const auth = req.headers.get("Authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (!m) throw new HttpError(401, "Missing Authorization: Bearer <access token> header.");
  const token = m[1].trim();

  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, noSession);
  const { data, error } = await anon.auth.getUser(token);
  if (error || !data?.user) throw new HttpError(401, "Your session is invalid or has expired. Sign in again.");
  return data.user;
}

type AppUserRow = { user_id: string; display_name: string | null; role: Role; active: boolean };

/** Confirms, with the service-role client (bypasses RLS), that the caller is an active admin. */
async function requireActiveAdmin(admin: SupabaseClient, user: User): Promise<AppUserRow> {
  const { data, error } = await admin
    .from("app_users")
    .select("user_id, display_name, role, active")
    .eq("user_id", user.id)
    .maybeSingle();
  if (error) throw new HttpError(500, `Couldn't read apparel.app_users: ${error.message}`);
  if (!data || !data.active || data.role !== "admin") {
    throw new HttpError(403, "Only active apparel admins can manage users.");
  }
  return data as AppUserRow;
}

async function getAppUser(admin: SupabaseClient, userId: string): Promise<AppUserRow> {
  const { data, error } = await admin
    .from("app_users")
    .select("user_id, display_name, role, active")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw new HttpError(500, `Couldn't read apparel.app_users: ${error.message}`);
  if (!data) throw new HttpError(404, "That person isn't an apparel app user.");
  return data as AppUserRow;
}

function forbidSelf(caller: User, targetId: string, what: string) {
  if (caller.id === targetId) throw new HttpError(400, `You can't ${what} your own account. Ask another admin.`);
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

type Ctx = { admin: SupabaseClient; caller: User; body: Record<string, unknown> };

async function actList({ admin }: Ctx) {
  const { data, error } = await admin.rpc("admin_list_users");
  if (error) {
    throw new HttpError(500, `Couldn't list users: ${error.message}. Has the move_to_apparel_schema migration been run?`);
  }
  return { users: data ?? [] };
}

async function actCreate({ admin, body }: Ctx) {
  const email = parseEmail(body.email);
  const password = parsePassword(body.password);
  const role = parseRole(body.role);
  const display_name = str(body.display_name, "display_name", { required: false, max: 120 }) || email.split("@")[0];

  // Does a login already exist for this email (e.g. from the other app)?
  const { data: existingId, error: lookupErr } = await admin.rpc("auth_user_id_by_email", { p_email: email });
  if (lookupErr) {
    throw new HttpError(500, `Couldn't check existing logins: ${lookupErr.message}. Has the move_to_apparel_schema migration been run?`);
  }

  let userId = (existingId as string | null) ?? null;
  let createdLogin = false;

  if (!userId) {
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { display_name },
    });
    if (error) {
      // Race / stale lookup: the login appeared between the lookup and the create.
      const already = /already|exists|registered/i.test(error.message);
      if (!already) throw new HttpError(error.status ?? 500, `Couldn't create the login: ${error.message}`);
      const { data: retryId } = await admin.rpc("auth_user_id_by_email", { p_email: email });
      userId = (retryId as string | null) ?? null;
      if (!userId) throw new HttpError(409, "A login with that email already exists but couldn't be looked up.");
    } else {
      userId = data.user.id;
      createdLogin = true;
    }
  }

  // Add (or re-activate) the app-user row. The temp password is NOT applied
  // to an existing login: that person already has a password for the shared
  // project, and an admin can use "reset password" explicitly if needed.
  const { data: existingRow } = await admin
    .from("app_users")
    .select("user_id, active")
    .eq("user_id", userId)
    .maybeSingle();
  if (existingRow?.active) throw new HttpError(409, "That person is already an active apparel user.");

  const { error: upsertErr } = await admin
    .from("app_users")
    .upsert({ user_id: userId, display_name, role, active: true }, { onConflict: "user_id" });
  if (upsertErr) throw new HttpError(500, `Login is ready but couldn't add the app-user row: ${upsertErr.message}`);

  return {
    ok: true,
    user_id: userId,
    email,
    role,
    display_name,
    created_login: createdLogin,
    message: createdLogin
      ? "Login created and added to the apparel app."
      : "That email already had a login, so it was added to the apparel app with its existing password.",
  };
}

async function actSetRole({ admin, caller, body }: Ctx) {
  const userId = parseUserId(body.user_id);
  const role = parseRole(body.role);
  forbidSelf(caller, userId, "change the role of");
  await getAppUser(admin, userId);
  const { error } = await admin.from("app_users").update({ role }).eq("user_id", userId);
  if (error) throw new HttpError(500, `Couldn't change role: ${error.message}`);
  return { ok: true, user_id: userId, role };
}

async function actSetDisplayName({ admin, body }: Ctx) {
  const userId = parseUserId(body.user_id);
  const display_name = str(body.display_name, "display_name", { max: 120 });
  await getAppUser(admin, userId);
  const { error } = await admin.from("app_users").update({ display_name }).eq("user_id", userId);
  if (error) throw new HttpError(500, `Couldn't rename: ${error.message}`);
  return { ok: true, user_id: userId, display_name };
}

async function actResetPassword({ admin, body }: Ctx) {
  const userId = parseUserId(body.user_id);
  const password = parsePassword(body.password);
  await getAppUser(admin, userId); // only apparel users can be touched from here
  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  if (error) throw new HttpError(error.status ?? 500, `Couldn't reset the password: ${error.message}`);
  return { ok: true, user_id: userId };
}

async function setActive({ admin, caller, body }: Ctx, active: boolean) {
  const userId = parseUserId(body.user_id);
  forbidSelf(caller, userId, active ? "reactivate" : "deactivate");
  await getAppUser(admin, userId);
  // Only the apparel "active" flag is flipped. The auth user is deliberately
  // NOT banned: this Supabase project is shared with another app and the
  // same login may still be valid there.
  const { error } = await admin.from("app_users").update({ active }).eq("user_id", userId);
  if (error) throw new HttpError(500, `Couldn't ${active ? "reactivate" : "deactivate"}: ${error.message}`);
  return { ok: true, user_id: userId, active };
}

const ACTIONS: Record<string, (ctx: Ctx) => Promise<unknown>> = {
  list: actList,
  create: actCreate,
  set_role: actSetRole,
  set_display_name: actSetDisplayName,
  reset_password: actResetPassword,
  deactivate: (ctx) => setActive(ctx, false),
  reactivate: (ctx) => setActive(ctx, true),
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }

  try {
    if (origin && !ALLOWED_ORIGINS.has(origin)) throw new HttpError(403, "Origin not allowed.");
    if (req.method !== "POST") throw new HttpError(405, "Use POST.");
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      throw new HttpError(500, "Function is missing its SUPABASE_* environment variables.");
    }

    let body: Record<string, unknown>;
    try {
      body = (await req.json()) as Record<string, unknown>;
    } catch {
      throw new HttpError(400, "Body must be JSON.");
    }
    if (!body || typeof body !== "object") throw new HttpError(400, "Body must be a JSON object.");

    const action = str(body.action, "action");
    const handler = ACTIONS[action];
    if (!handler) throw new HttpError(400, `Unknown action "${action}". Expected one of: ${Object.keys(ACTIONS).join(", ")}.`);

    const caller = await requireCaller(req);
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, adminOpts);
    await requireActiveAdmin(admin, caller);

    const result = await handler({ admin, caller, body });
    return json(result, 200, origin);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status, origin);
    console.error("admin-users unexpected error", e);
    return json({ error: "Unexpected error. Check the function logs." }, 500, origin);
  }
});
