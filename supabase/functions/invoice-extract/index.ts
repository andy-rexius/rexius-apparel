// Rexius Apparel — invoice-extract Edge Function
//
// Reads a vendor invoice (PDF or photo already uploaded to the private
// "apparel-invoices" bucket) with Claude and returns the header fields and
// one row per product line, each matched to one of our items where it can.
//
// Request:  POST /functions/v1/invoice-extract
//           Authorization: Bearer <caller's Supabase access token>
//           apikey: <anon key>
//           body: { "invoice_id": "<uuid of apparel.invoices row>" }
//
// Response: {
//   header: { vendor, invoice_no, invoice_date, subtotal, total },
//   lines: [{ description, vendor_sku, qty, unit_cost, line_total,
//             item_id, match: "alias" | "suggested" | "none",
//             confidence: "high" | "medium" | "low" | "none", note }],
//   other_charges: [{ description, amount }],
//   notes: string
// }
//
// Matching order: a saved vendor alias (apparel.vendor_aliases) always wins;
// otherwise the model's best guess from the item catalog is returned as a
// suggestion for the person to confirm on the review screen. Nothing is
// written to the database here — the page does that after review.
//
// Secrets: ANTHROPIC_API_KEY (set with `supabase secrets set`), plus the
// SUPABASE_* variables Supabase injects. Deployed with gateway JWT
// verification off (supabase/config.toml); the function verifies the token
// itself and requires an active admin.

import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.45.4";
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { zodOutputFormat } from "npm:@anthropic-ai/sdk@1.3.0/helpers/zod";
import { z } from "npm:zod@3.25.76";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

const BUCKET = "apparel-invoices";
const MODEL = "claude-opus-5-5";
const MAX_FILE_BYTES = 20 * 1024 * 1024;

const ALLOWED_ORIGINS = new Set<string>([
  "https://rexiusfleet.github.io",
  ...(Deno.env.get("APPAREL_EXTRA_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean),
]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
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

/** Same normalization the page uses: lower-case, single spaces, trimmed. */
export function normKey(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
}

const noSession = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const adminOpts = { ...noSession, db: { schema: "apparel" } };

async function requireCaller(req: Request): Promise<User> {
  const m = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "");
  if (!m) throw new HttpError(401, "Missing Authorization: Bearer <access token> header.");
  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, noSession);
  const { data, error } = await anon.auth.getUser(m[1].trim());
  if (error || !data?.user) throw new HttpError(401, "Your session is invalid or has expired. Sign in again.");
  return data.user;
}

async function requireActiveAdmin(admin: SupabaseClient, user: User): Promise<void> {
  const { data, error } = await admin.from("app_users").select("role, active").eq("user_id", user.id).maybeSingle();
  if (error) throw new HttpError(500, `Couldn't read apparel.app_users: ${error.message}`);
  if (!data || !data.active || data.role !== "admin") throw new HttpError(403, "Only active apparel admins can read invoices.");
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(bin);
}

// ---------------------------------------------------------------------------
// What we ask Claude for
// ---------------------------------------------------------------------------

const Line = z.object({
  description: z.string().describe("The line's description exactly as printed, trimmed."),
  vendor_sku: z.string().nullable().describe("The vendor's SKU / item / part number for the line, exactly as printed, or null if the invoice shows none."),
  qty: z.number().describe("Number of individual units received. If the invoice bills by pack or case and shows the pack size, multiply out to units and say so in note."),
  unit_cost: z.number().nullable().describe("Cost per individual unit after any line-level discount, excluding tax and freight. Null if it truly cannot be determined."),
  line_total: z.number().nullable().describe("Extended total for the line as printed, or null."),
  item_id: z.string().nullable().describe("The id of the catalog item this line is, or null if no catalog item plausibly matches. Match on product, class/type, colour and SIZE — size must match exactly."),
  confidence: z.enum(["high", "medium", "low", "none"]).describe("How sure you are about item_id. 'none' when item_id is null."),
  note: z.string().nullable().describe("Anything the reviewer should know: pack conversions, ambiguity, a size we don't stock, etc. Null if nothing."),
});

const Extraction = z.object({
  vendor: z.string().describe("The vendor / seller name as printed."),
  invoice_no: z.string().nullable(),
  invoice_date: z.string().nullable().describe("YYYY-MM-DD, or null."),
  subtotal: z.number().nullable(),
  total: z.number().nullable().describe("Grand total due as printed."),
  lines: z.array(Line).describe("One entry per PRODUCT line. Do not include freight, shipping, tax, discounts, deposits or payment lines here."),
  other_charges: z.array(z.object({ description: z.string(), amount: z.number() })).describe("Freight, shipping, handling, tax and other non-product amounts."),
  notes: z.string().nullable().describe("General remarks about the document (poor scan, multiple pages, credit memo, etc.)."),
});
type ExtractionT = z.infer<typeof Extraction>;

type Item = { id: string; name: string; size: string | null; sku: string | null; category: string | null; active: boolean };
type Alias = { vendor_key: string; alias_key: string; item_id: string };

function systemPrompt(items: Item[]): string {
  const catalog = items.map((i) => ({ id: i.id, name: i.name, size: i.size ?? "", sku: i.sku ?? "", category: i.category ?? "" }));
  return [
    "You read apparel vendor invoices for an internal inventory app and return structured data for a person to review before anything is recorded.",
    "The company stocks branded high-visibility work apparel in multiple sizes. Each size is a separate catalog item.",
    "",
    "Rules:",
    "- Return every product line on the invoice, in the order printed. Skip nothing, invent nothing.",
    "- Quantities are individual units. If a line is priced per pack/case/dozen and the pack size is shown, convert to units and per-unit cost and explain in note. If the pack size is not shown, leave qty as printed and flag it in note.",
    "- unit_cost is per unit after line discounts, before tax/freight. Use the extended total divided by units when the printed unit price disagrees with the extension.",
    "- Match each line to a catalog item only when product AND size clearly agree. Vendor wording differs from ours (abbreviations, part numbers, colour codes); use judgement on the product but never on the size. If the size on the invoice is not in the catalog, item_id is null and note says which size.",
    "- Dates are YYYY-MM-DD.",
    "- If the document is not an invoice (packing slip, quote, statement), still extract what you can and say so in notes.",
    "",
    "Catalog (JSON, one object per item):",
    JSON.stringify(catalog),
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function extract(admin: SupabaseClient, invoiceId: string) {
  const { data: inv, error: invErr } = await admin.from("invoices").select("id, vendor, file_path, file_name, content_type, size_bytes").eq("id", invoiceId).maybeSingle();
  if (invErr) throw new HttpError(500, `Couldn't read the invoice: ${invErr.message}`);
  if (!inv) throw new HttpError(404, "That invoice doesn't exist.");
  if ((inv.size_bytes ?? 0) > MAX_FILE_BYTES) throw new HttpError(413, "That file is over 20 MB. Re-scan at a lower resolution or split it.");

  const { data: blob, error: dlErr } = await admin.storage.from(BUCKET).download(inv.file_path);
  if (dlErr || !blob) throw new HttpError(500, `Couldn't download the file: ${dlErr?.message ?? "no data"}`);
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > MAX_FILE_BYTES) throw new HttpError(413, "That file is over 20 MB. Re-scan at a lower resolution or split it.");

  const mime = (inv.content_type || blob.type || "").toLowerCase();
  const name = (inv.file_name || "").toLowerCase();
  let media: Anthropic.ContentBlockParam;
  if (mime === "application/pdf" || name.endsWith(".pdf")) {
    media = { type: "document", source: { type: "base64", media_type: "application/pdf", data: bytesToBase64(bytes) }, title: inv.file_name || "Invoice" };
  } else if (["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime)) {
    media = { type: "image", source: { type: "base64", media_type: mime as "image/jpeg" | "image/png" | "image/webp" | "image/gif", data: bytesToBase64(bytes) } };
  } else if (mime === "image/heic" || mime === "image/heif" || name.endsWith(".heic")) {
    throw new HttpError(415, "HEIC photos can't be read yet. Take the photo again with the camera set to 'Most compatible', or save it as JPEG or PDF first.");
  } else {
    throw new HttpError(415, `Unsupported file type (${mime || "unknown"}). Use a PDF, JPEG or PNG.`);
  }

  const [{ data: items, error: itErr }, { data: aliases, error: alErr }] = await Promise.all([
    admin.from("items").select("id, name, size, sku, category, active").eq("active", true).order("name").order("size"),
    admin.from("vendor_aliases").select("vendor_key, alias_key, item_id"),
  ]);
  if (itErr) throw new HttpError(500, `Couldn't load items: ${itErr.message}`);
  if (alErr) throw new HttpError(500, `Couldn't load vendor matches: ${alErr.message}`);

  const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
  const response = await client.messages.parse({
    model: MODEL,
    max_tokens: 16000,
    output_config: { effort: "high", format: zodOutputFormat(Extraction) },
    system: systemPrompt((items ?? []) as Item[]),
    messages: [{
      role: "user",
      content: [
        media,
        { type: "text", text: `Extract this invoice${inv.vendor ? ` (we filed it under vendor "${inv.vendor}")` : ""}.` },
      ],
    }],
  });

  if (response.stop_reason === "refusal") throw new HttpError(422, "The document couldn't be processed. Try a clearer scan.");
  if (response.stop_reason === "max_tokens") throw new HttpError(422, "The invoice is too long to read in one go. Split it into smaller files.");
  const parsed = response.parsed_output as ExtractionT | null;
  if (!parsed) throw new HttpError(502, "Claude returned an unreadable answer. Try again.");

  // Saved matches win over the model's guesses.
  const itemIds = new Set((items ?? []).map((i: Item) => i.id));
  const vendorKey = normKey(parsed.vendor) || normKey(inv.vendor);
  const aliasMap = new Map<string, string>();
  for (const a of (aliases ?? []) as Alias[]) aliasMap.set(`${a.vendor_key}\u0000${a.alias_key}`, a.item_id);
  const lookup = (vk: string, key: string) => (key ? aliasMap.get(`${vk}\u0000${key}`) : undefined);

  const lines = parsed.lines.map((l) => {
    const skuKey = normKey(l.vendor_sku), descKey = normKey(l.description);
    const aliasHit = lookup(vendorKey, skuKey) ?? lookup(vendorKey, descKey) ?? lookup(normKey(inv.vendor), skuKey) ?? lookup(normKey(inv.vendor), descKey);
    if (aliasHit && itemIds.has(aliasHit)) return { ...l, item_id: aliasHit, match: "alias" as const, confidence: "high" as const };
    const suggested = l.item_id && itemIds.has(l.item_id) ? l.item_id : null;
    return { ...l, item_id: suggested, match: suggested ? ("suggested" as const) : ("none" as const), confidence: suggested ? l.confidence : ("none" as const) };
  });

  return {
    header: { vendor: parsed.vendor, invoice_no: parsed.invoice_no, invoice_date: parsed.invoice_date, subtotal: parsed.subtotal, total: parsed.total },
    lines,
    other_charges: parsed.other_charges,
    notes: parsed.notes,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens, model: response.model },
  };
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) });

  try {
    if (origin && !ALLOWED_ORIGINS.has(origin)) throw new HttpError(403, "Origin not allowed.");
    if (req.method !== "POST") throw new HttpError(405, "Use POST.");
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) throw new HttpError(500, "Function is missing its SUPABASE_* environment variables.");
    if (!ANTHROPIC_API_KEY) throw new HttpError(500, "ANTHROPIC_API_KEY isn't set. Add it with: supabase secrets set ANTHROPIC_API_KEY=...");

    let body: Record<string, unknown>;
    try { body = (await req.json()) as Record<string, unknown>; } catch { throw new HttpError(400, "Body must be JSON."); }
    const invoiceId = typeof body?.invoice_id === "string" ? body.invoice_id.trim() : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(invoiceId)) throw new HttpError(400, "invoice_id must be a UUID.");

    const caller = await requireCaller(req);
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, adminOpts);
    await requireActiveAdmin(admin, caller);

    return json(await extract(admin, invoiceId), 200, origin);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status, origin);
    if (e instanceof Anthropic.APIError) {
      console.error("invoice-extract Claude API error", e.status, e.message);
      return json({ error: `Claude API error (${e.status}): ${e.message}` }, 502, origin);
    }
    console.error("invoice-extract unexpected error", e);
    return json({ error: "Unexpected error. Check the function logs." }, 500, origin);
  }
});
