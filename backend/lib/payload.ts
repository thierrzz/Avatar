/**
 * Thin Payload-CMS REST client used by the announcement endpoints.
 *
 * The CMS (admin.aaavatar.nl) is the source of truth for announcement
 * content. The backend reads it via Payload's auto-generated REST API and
 * caches the result for a short window so the macOS-app sign-in path
 * doesn't pay a cross-region round-trip on every call.
 *
 * Auth: a Payload "API Keys" user (created in Payload's Users collection
 * with `enableAPIKey: true`) — the backend sends `Authorization: users
 * API-Key <key>` and Payload skips its session/cookie checks.
 */
const PAYLOAD_API_URL = process.env.PAYLOAD_API_URL ?? "";
const PAYLOAD_API_KEY = process.env.PAYLOAD_API_KEY ?? "";

/**
 * Normalize `PAYLOAD_API_URL` into a valid http(s) base, or `null` when it is
 * missing/malformed. A bare host without a scheme (e.g. `admin.aaavatar.nl`)
 * is the misconfig that made `fetch` throw `TypeError: fetch failed` /
 * "unknown scheme" — `new URL` then parses the host as the scheme. We prepend
 * `https://` so a scheme-less value still works, and validate the result so
 * genuine garbage disables the CMS gracefully (return `[]`/`false`) instead of
 * throwing on every call.
 */
function payloadBase(): string | null {
  let u = PAYLOAD_API_URL.trim().replace(/\/+$/, "");
  if (!u) return null;
  if (!/^https?:\/\//i.test(u)) u = `https://${u}`;
  try {
    const parsed = new URL(u);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return u;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// E52.1 — thumbnail-varianten via Supabase image-transformatie.
//
// Media wordt (sinds 837498f) als ORIGINEEL via directe Supabase Storage-URL's
// geserveerd; panels decodeerden dus full-size bronnen voor ~100–200 pt
// grid-cellen. Supabase's image-transformation-API levert een verkleinde,
// CDN-gecachete variant door `/object/public/…` te herschrijven naar
// `/render/image/public/…?width=…&quality=…` — geen re-upload nodig.
// Geverifieerd op het productie-project (2026-07-02): 200 OK, geldige JPEG,
// cf-cache-status HIT op de tweede hit.
// ---------------------------------------------------------------------------

/**
 * Rewrite a Supabase Storage public-object URL into its image-transformation
 * (thumbnail) variant. Non-Supabase URLs are returned unchanged so a future
 * CDN swap degrades gracefully. Een eventuele querystring op de object-URL
 * (Payload's S3-plugin hangt er sinds de E54-admin-deploy `?prefix=media`
 * aan) wordt genegeerd: het pad identificeert het object volledig.
 *
 * `width` is een MAX-EDGE, geen breedte: we vragen een vierkante box
 * (`width`×`width`) op met `resize=contain`, wat proportioneel binnenin past
 * zonder te padden (geverifieerd 2026-08-03: 800×800 → 320×320, en een
 * 320×160-box → 160×160). Zónder `height`/`resize` valt Supabase terug op
 * cover mét de originele hoogte: een 800×800-bron kwam er als 320×800 uit —
 * een center-crop die de linker- en rechterhelft weggooide. Dat trof elke
 * CMS-thumbnail én de stijl-referenties die naar het model gaan.
 */
export function thumbnailVariant(
  url: string | null,
  width = 320,
  quality = 75,
): string | null {
  if (!url) return null;
  const m = url.match(/^(https?:\/\/[^/]+\/storage\/v1)\/object\/public\/([^?]+)/);
  if (!m) {
    // E55.5: luid falen i.p.v. stil doorlaten. Een niet-matchende URL betekent
    // meestal een admin-deploy zonder de generateFileURL-fix (837498f) — de
    // app krijgt dan een full-size origineel (traag) of een MFA-geblokkeerde
    // proxy-URL (kapot). De passthrough blijft (graceful degradation), maar
    // nooit meer onzichtbaar.
    console.warn(`[payload] thumbnailVariant: URL matcht de Supabase-objectvorm niet, passthrough full-size: ${url}`);
    return url;
  }
  return `${m[1]}/render/image/public/${m[2]}?width=${width}&height=${width}&resize=contain&quality=${quality}`;
}

/**
 * Shared Cache-Control for the anonymous CMS-list endpoints (E52.1). The
 * lists change rarely (Thierry seeds content); a 60s browser-cache plus a
 * 5-minute CDN-cache with stale-while-revalidate keeps panel-opens off the
 * Payload round-trip without making CMS edits feel laggy.
 */
export const CMS_LIST_CACHE_CONTROL =
  "public, max-age=60, s-maxage=300, stale-while-revalidate=600";

/** What the backend needs from one Payload announcement document. */
export type PayloadAnnouncement = {
  slug: string;
  title: string;
  body: string;
  imageUrl: string | null;
  cta: { label: string; url: string } | null;
  frequency: "once" | "everySignInUntilDismissed" | "untilDate" | "delayedNthSignIn";
  untilDate: string | null;
  delayN: number | null;
  audience: "all" | "freeUsers" | "proUsers" | "specificEmails";
  audienceEmails: string[];
  minAppVersion: string | null;
  /** Upper bound (inclusive) — lets a "2.0 is out" notice target 1.x
   *  installs only. Clients that send no X-App-Version are treated as old. */
  maxAppVersion: string | null;
  publishedAt: string | null;
  expiresAt: string | null;
  badgeTargets: { componentId: string; durationDays: number }[];
  newsletter: {
    send: boolean;
    sentAt: string | null;
  } | null;
};

type CacheEntry = {
  expiresAt: number;
  payload: PayloadAnnouncement[];
};

/**
 * 60-second in-process cache. Vercel functions are short-lived but a single
 * warm instance can serve dozens of /pending calls back-to-back during a
 * sign-in spike (e.g. after a release announcement goes live). Avoiding
 * the Payload round-trip on each one keeps p95 well under 200 ms.
 */
let cache: CacheEntry | null = null;
const CACHE_TTL_MS = 60_000;

export async function fetchPublishedAnnouncements(): Promise<PayloadAnnouncement[]> {
  const now = Date.now();
  if (cache && cache.expiresAt > now) {
    return cache.payload;
  }

  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    // Misconfigured (missing/invalid URL or key) → return empty so the macOS
    // app never sees a 500 on a path that's only loosely critical.
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — announcements disabled");
    return [];
  }

  // Fetch published, non-expired announcements. Payload uses the `where`
  // querystring with bracketed operators.
  const url = new URL(`${base}/announcements`);
  url.searchParams.set("limit", "100");
  url.searchParams.set("depth", "1");
  url.searchParams.set("where[publishedAt][exists]", "true");
  url.searchParams.set("where[publishedAt][less_than_equal]", new Date().toISOString());

  const res = await fetch(url, {
    headers: {
      Authorization: `users API-Key ${PAYLOAD_API_KEY}`,
      Accept: "application/json",
    },
  });
  if (!res.ok) {
    console.error("Payload fetch failed", res.status, await res.text().catch(() => ""));
    return [];
  }

  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const announcements = docs.map(normalize).filter((a): a is PayloadAnnouncement => a !== null);

  cache = { expiresAt: now + CACHE_TTL_MS, payload: announcements };
  return announcements;
}

/**
 * Coerce a Payload document (loosely typed JSON) into the shape the
 * backend consumes. Payload nests upload references as `{ url, ... }`
 * objects when `depth>=1`; richText fields ship as a Lexical AST that we
 * flatten to a Markdown-ish string here so the macOS client can render it
 * with `AttributedString(markdown:)`.
 */
function normalize(raw: unknown): PayloadAnnouncement | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;

  const slug = typeof r.slug === "string" ? r.slug : null;
  const title = typeof r.title === "string" ? r.title : null;
  if (!slug || !title) return null;

  const image = r.image as { url?: string } | null | undefined;
  const imageUrl = image && typeof image.url === "string" ? image.url : null;

  const cta = (() => {
    const c = r.primaryCta as { label?: string; url?: string } | null | undefined;
    if (!c || typeof c.label !== "string" || typeof c.url !== "string") return null;
    if (!c.label.trim() || !c.url.trim()) return null;
    return { label: c.label, url: c.url };
  })();

  const frequency = (() => {
    const f = r.frequency;
    if (
      f === "once" ||
      f === "everySignInUntilDismissed" ||
      f === "untilDate" ||
      f === "delayedNthSignIn"
    ) {
      return f;
    }
    return "once";
  })();

  const audience = (() => {
    const a = r.audience;
    if (a === "all" || a === "freeUsers" || a === "proUsers" || a === "specificEmails") {
      return a;
    }
    return "all";
  })();

  const audienceEmails = Array.isArray(r.audienceEmails)
    ? (r.audienceEmails as unknown[])
        .map((e) => (typeof e === "object" && e !== null ? (e as { email?: string }).email : e))
        .filter((e): e is string => typeof e === "string" && e.trim().length > 0)
        .map((e) => e.trim().toLowerCase())
    : [];

  const badgeTargets = Array.isArray(r.badgeTargets)
    ? (r.badgeTargets as unknown[])
        .map((b) => {
          if (typeof b !== "object" || b === null) return null;
          const o = b as { componentId?: unknown; durationDays?: unknown };
          if (typeof o.componentId !== "string") return null;
          const days = typeof o.durationDays === "number" ? o.durationDays : 14;
          return { componentId: o.componentId, durationDays: days };
        })
        .filter((b): b is { componentId: string; durationDays: number } => b !== null)
    : [];

  const newsletter = (() => {
    const n = r.newsletter as
      | { send?: unknown; sentAt?: unknown }
      | null
      | undefined;
    if (!n || typeof n !== "object") return null;
    return {
      send: n.send === true,
      sentAt: typeof n.sentAt === "string" ? n.sentAt : null,
    };
  })();

  return {
    slug,
    title,
    body: lexicalToMarkdown(r.body),
    imageUrl,
    cta,
    frequency,
    untilDate: typeof r.untilDate === "string" ? r.untilDate : null,
    delayN: typeof r.delayN === "number" ? r.delayN : null,
    audience,
    audienceEmails,
    minAppVersion: typeof r.minAppVersion === "string" ? r.minAppVersion : null,
    maxAppVersion: typeof r.maxAppVersion === "string" && r.maxAppVersion.trim() ? r.maxAppVersion.trim() : null,
    publishedAt: typeof r.publishedAt === "string" ? r.publishedAt : null,
    expiresAt: typeof r.expiresAt === "string" ? r.expiresAt : null,
    badgeTargets,
    newsletter,
  };
}

/**
 * Walk a Lexical rich-text AST and emit Markdown. Covers the node types
 * used in the announcement body — paragraph, heading, list, list-item,
 * link, bold/italic. Unknown nodes contribute their text content without
 * formatting so a future schema change degrades gracefully instead of
 * blanking the body.
 */
function lexicalToMarkdown(raw: unknown): string {
  if (typeof raw === "string") return raw;
  if (typeof raw !== "object" || raw === null) return "";
  const root = (raw as { root?: { children?: unknown[] } }).root;
  const children = Array.isArray(root?.children) ? root!.children! : [];
  return children.map(renderNode).join("\n\n").trim();
}

// Schemes a link in the in-app Markdown body may use. The macOS client renders
// this body via `AttributedString(markdown:)` and taps go through SwiftUI's
// default openURL with no scheme guard, so a `file:`/other hostile scheme in an
// author-supplied link must not survive into a navigable link. Mirrors the
// email renderer's `safeUrl` (admin/src/lib/lexical.ts). The WHATWG URL parser
// also neutralises control-char scheme smuggling (`java&#9;script:`).
const ALLOWED_LINK_SCHEMES = new Set(["http:", "https:", "mailto:", "aaavatar:"]);

function safeLinkUrl(url: string | undefined): string | null {
  if (typeof url !== "string") return null;
  const trimmed = url.trim();
  if (!trimmed) return null;
  let scheme: string;
  try {
    scheme = new URL(trimmed, "https://aaavatar.invalid/").protocol;
  } catch {
    return null;
  }
  return ALLOWED_LINK_SCHEMES.has(scheme) ? trimmed : null;
}

function renderNode(node: unknown): string {
  if (typeof node !== "object" || node === null) return "";
  const n = node as { type?: string; tag?: string; text?: string; format?: number; url?: string; children?: unknown[]; listType?: string };

  if (n.type === "text" && typeof n.text === "string") {
    let t = n.text;
    const fmt = typeof n.format === "number" ? n.format : 0;
    if (fmt & 1) t = `**${t}**`;     // bold
    if (fmt & 2) t = `*${t}*`;       // italic
    if (fmt & 4) t = `~~${t}~~`;     // strikethrough
    if (fmt & 16) t = `\`${t}\``;    // code
    return t;
  }

  const inner = (n.children ?? []).map(renderNode).join("");
  switch (n.type) {
    case "paragraph": return inner;
    case "heading":   return `${"#".repeat(headingLevel(n.tag))} ${inner}`;
    case "link": {
      const href = safeLinkUrl(n.url);
      return href ? `[${inner}](${href})` : inner;
    }
    case "list":      return inner;
    case "listitem": {
      const bullet = n.listType === "number" ? "1." : "-";
      return `${bullet} ${inner}`;
    }
    case "linebreak": return "\n";
    default:          return inner;
  }
}

function headingLevel(tag: string | undefined): number {
  if (!tag) return 2;
  const m = tag.match(/^h([1-6])$/);
  return m ? Number(m[1]) : 2;
}

/**
 * Records a newsletter unsubscribe in Payload's `newsletter-unsubscribes`
 * collection (audit HIGH #15). Idempotent — the collection has a unique
 * index on `email`, so re-clicking a stale link is a no-op. Returns true
 * when the row was created OR already existed (i.e. the user is now
 * opted-out); false on configuration / transport failure.
 */
export async function recordNewsletterUnsubscribe(
  email: string,
  source: "one_click" | "list_unsubscribe_post" | "manual" = "one_click",
): Promise<boolean> {
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — unsubscribe NOT recorded");
    return false;
  }

  const url = `${base}/newsletter-unsubscribes`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `users API-Key ${PAYLOAD_API_KEY}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ email: email.trim().toLowerCase(), source }),
  });

  if (res.ok) return true;

  // The unique index makes a second click return 400 with a Postgres
  // duplicate-key error wrapped in Payload's error envelope. Treat it as
  // success — the user is opted out either way.
  if (res.status === 400) {
    const text = await res.text().catch(() => "");
    if (/duplicate|unique/i.test(text)) return true;
    console.warn("unsubscribe POST 400 (not duplicate)", text);
    return false;
  }
  console.error("unsubscribe POST failed", res.status, await res.text().catch(() => ""));
  return false;
}

// ---------------------------------------------------------------------------
// E33 — Effects (CMS-gestuurde stijlen, slug "effects"). Spiegelt
// admin/src/collections/Effects.ts: key + label + thumbnail + prompt + order.
// Vervangt de hardgecodeerde StylizeStyle/STYLE_PROMPTS zodat een nieuw effect
// zonder app- of backend-deploy kan worden toegevoegd. De `prompt` blijft
// server-side (alleen /v1/stylize gebruikt 'm); /v1/effects laat 'm weg.
// ---------------------------------------------------------------------------

export type PayloadEffect = {
  key: string;
  label: string;
  prompt: string;
  thumbnailUrl: string | null;
  /** E54: server-only stijlvoorbeelden, in CMS-volgorde (max 4 rijen). */
  styleReferenceUrls: string[];
  order: number;
};

let effectCache: { expiresAt: number; payload: PayloadEffect[] } | null = null;

export async function fetchActiveEffects(): Promise<PayloadEffect[]> {
  const now = Date.now();
  if (effectCache && effectCache.expiresAt > now) {
    return effectCache.payload;
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — effects disabled");
    return [];
  }

  const url = new URL(`${base}/effects`);
  url.searchParams.set("limit", "100");
  url.searchParams.set("depth", "1"); // resolve the thumbnail upload → { url }
  url.searchParams.set("where[active][equals]", "true");
  url.searchParams.set("sort", "order");

  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload effects fetch failed", res.status, await res.text().catch(() => ""));
    return [];
  }
  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const effects = docs.map(normalizeEffect).filter((e): e is PayloadEffect => e !== null);
  effectCache = { expiresAt: now + CACHE_TTL_MS, payload: effects };
  return effects;
}

function normalizeEffect(raw: unknown): PayloadEffect | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const key = typeof r.key === "string" ? r.key.trim() : null;
  const prompt = typeof r.prompt === "string" ? r.prompt.trim() : null;
  // Onbruikbaar zonder key + prompt (de stijl kan dan niet renderen) → skip.
  if (!key || !prompt) return null;
  const label = typeof r.label === "string" && r.label.trim() ? r.label.trim() : key;
  const thumb = r.thumbnail as { url?: string } | null | undefined;
  const thumbnailUrl = thumb && typeof thumb.url === "string" ? thumb.url : null;
  // E54: `styleReferences` is een Payload-array van { image: upload }; depth=1
  // resolvet elke upload naar { url }. Rijen zonder bruikbare url slaan we over.
  const refRows = Array.isArray(r.styleReferences) ? r.styleReferences : [];
  const styleReferenceUrls = refRows
    .map((row) => {
      if (typeof row !== "object" || row === null) return null;
      const image = (row as Record<string, unknown>).image as { url?: string } | null | undefined;
      return image && typeof image.url === "string" ? image.url : null;
    })
    .filter((u): u is string => u !== null);
  const order = typeof r.order === "number" ? r.order : 99;
  return { key, label, prompt, thumbnailUrl, styleReferenceUrls, order };
}

// ---------------------------------------------------------------------------
// E39 — Banner-presets (CMS-gestuurde startpunten, slug "banner-presets").
// Spiegelt admin/src/collections/BannerPresets.ts: key + label + category +
// thumbnail + config (JSON-string van de app's BannerLayers) + order. Een nieuw
// banner-startpunt kan zo zonder app- of backend-deploy worden toegevoegd. De
// `config` is een ondoorzichtige JSON-string die alléén de app decodeert; de
// backend reikt 'm onbewerkt door.
// ---------------------------------------------------------------------------

export type PayloadBannerPreset = {
  key: string;
  label: string;
  category: string;
  thumbnailUrl: string | null;
  config: string;
  order: number;
};

let bannerPresetCache: { expiresAt: number; payload: PayloadBannerPreset[] } | null = null;

export async function fetchActiveBannerPresets(): Promise<PayloadBannerPreset[]> {
  const now = Date.now();
  if (bannerPresetCache && bannerPresetCache.expiresAt > now) {
    return bannerPresetCache.payload;
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — banner presets disabled");
    return [];
  }

  const url = new URL(`${base}/banner-presets`);
  url.searchParams.set("limit", "100");
  url.searchParams.set("depth", "1"); // resolve the thumbnail upload → { url }
  url.searchParams.set("where[active][equals]", "true");
  url.searchParams.set("sort", "order");

  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload banner-presets fetch failed", res.status, await res.text().catch(() => ""));
    return [];
  }
  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const presets = docs.map(normalizeBannerPreset).filter((p): p is PayloadBannerPreset => p !== null);
  bannerPresetCache = { expiresAt: now + CACHE_TTL_MS, payload: presets };
  return presets;
}

function normalizeBannerPreset(raw: unknown): PayloadBannerPreset | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const key = typeof r.key === "string" ? r.key.trim() : null;
  const config = typeof r.config === "string" ? r.config.trim() : null;
  // Onbruikbaar zonder key + config (de preset kan dan geen laagstack vormen) → skip.
  if (!key || !config) return null;
  const label = typeof r.label === "string" && r.label.trim() ? r.label.trim() : key;
  const category = typeof r.category === "string" && r.category.trim() ? r.category.trim() : "default";
  const thumb = r.thumbnail as { url?: string } | null | undefined;
  const thumbnailUrl = thumb && typeof thumb.url === "string" ? thumb.url : null;
  const order = typeof r.order === "number" ? r.order : 99;
  return { key, label, category, thumbnailUrl, config, order };
}

// ---------------------------------------------------------------------------
// Backgrounds — CMS-gestuurde achtergronden (E33+). Elke rij is één swatch in
// het Background-paneel van de macOS Editor, gegroepeerd op `category`.
// De volledige afbeelding (`imageUrl`) dient voor compositing; `thumbnailUrl`
// is de kleine swatch voor de panel-preview (valt terug op imageUrl).
// ---------------------------------------------------------------------------

export type PayloadBackground = {
  key: string;
  label: string;
  category: string;
  imageUrl: string;
  thumbnailUrl: string | null;
  order: number;
};

let backgroundCache: { expiresAt: number; payload: PayloadBackground[] } | null = null;

export async function fetchActiveBackgrounds(): Promise<PayloadBackground[]> {
  const now = Date.now();
  if (backgroundCache && backgroundCache.expiresAt > now) {
    return backgroundCache.payload;
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — backgrounds disabled");
    return [];
  }

  const url = new URL(`${base}/backgrounds`);
  url.searchParams.set("limit", "200");
  url.searchParams.set("depth", "1");
  url.searchParams.set("where[active][equals]", "true");
  url.searchParams.set("sort", "category,order");

  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload backgrounds fetch failed", res.status, await res.text().catch(() => ""));
    return [];
  }
  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const backgrounds = docs.map(normalizeBackground).filter((b): b is PayloadBackground => b !== null);
  backgroundCache = { expiresAt: now + CACHE_TTL_MS, payload: backgrounds };
  return backgrounds;
}

function normalizeBackground(raw: unknown): PayloadBackground | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const key = typeof r.key === "string" ? r.key.trim() : null;
  const category = typeof r.category === "string" ? r.category.trim() : null;
  const img = r.image as { url?: string } | null | undefined;
  const imageUrl = img && typeof img.url === "string" ? img.url : null;
  if (!key || !category || !imageUrl) return null;
  const label = typeof r.label === "string" && r.label.trim() ? r.label.trim() : key;
  const thumb = r.thumbnail as { url?: string } | null | undefined;
  const thumbnailUrl = thumb && typeof thumb.url === "string" ? thumb.url : null;
  const order = typeof r.order === "number" ? r.order : 99;
  return { key, label, category, imageUrl, thumbnailUrl, order };
}

// ---------------------------------------------------------------------------
// AppConfig — singleton Global voor app-brede visuele configuratie (E33+).
// Payload-endpoint: GET /api/globals/app-config?depth=1
//
// splashBackgroundUrl — achtergrond Onboarding Splash-scherm (was hardcoded gradient)
// emptyStateAvatarUrls — maximaal 6 portret-voorbeelden in de lege-canvas-cirkels
//
// Beide vallen terug op de ingebouwde placeholder als het veld leeg is.
// ---------------------------------------------------------------------------

export type PayloadAppConfig = {
  splashBackgroundUrl: string | null;
  emptyStateAvatarUrls: string[];
  gradientPresets: Array<{ label: string; fromHex: string; toHex: string }>;
  paywallProFeatures: string[];
};

let appConfigCache: { expiresAt: number; payload: PayloadAppConfig } | null = null;

export async function fetchAppConfig(): Promise<PayloadAppConfig> {
  const now = Date.now();
  if (appConfigCache && appConfigCache.expiresAt > now) {
    return appConfigCache.payload;
  }
  const base = payloadBase();
  const empty: PayloadAppConfig = {
    splashBackgroundUrl: null,
    emptyStateAvatarUrls: [],
    gradientPresets: [],
    paywallProFeatures: [],
  };
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL/KEY missing — app-config disabled");
    return empty;
  }

  const url = new URL(`${base}/globals/app-config`);
  url.searchParams.set("depth", "1");

  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload app-config fetch failed", res.status, await res.text().catch(() => ""));
    return empty;
  }
  const doc = (await res.json()) as Record<string, unknown>;

  const splashRef = doc.splashBackground as { url?: string } | null | undefined;
  const splashBackgroundUrl = splashRef && typeof splashRef.url === "string" ? splashRef.url : null;

  const rawAvatars = Array.isArray(doc.emptyStateAvatars) ? doc.emptyStateAvatars : [];
  const emptyStateAvatarUrls: string[] = rawAvatars
    .map((item: unknown) => {
      if (typeof item !== "object" || item === null) return null;
      const img = (item as Record<string, unknown>).image as { url?: string } | null | undefined;
      return img && typeof img.url === "string" ? img.url : null;
    })
    .filter((u): u is string => u !== null);

  const rawGradients = Array.isArray(doc.gradientPresets) ? doc.gradientPresets : [];
  const gradientPresets: Array<{ label: string; fromHex: string; toHex: string }> = rawGradients
    .map((g: unknown) => {
      if (typeof g !== "object" || g === null) return null;
      const o = g as Record<string, unknown>;
      const label = typeof o.label === "string" ? o.label.trim() : "";
      const fromHex = typeof o.fromHex === "string" ? o.fromHex.trim() : "";
      const toHex = typeof o.toHex === "string" ? o.toHex.trim() : "";
      if (!fromHex || !toHex) return null;
      return { label: label || "Gradient", fromHex, toHex };
    })
    .filter((g): g is { label: string; fromHex: string; toHex: string } => g !== null);

  const rawBullets = Array.isArray(doc.paywallProFeatures) ? doc.paywallProFeatures : [];
  const paywallProFeatures: string[] = rawBullets
    .map((b: unknown) => {
      if (typeof b !== "object" || b === null) return null;
      const text = (b as Record<string, unknown>).text;
      return typeof text === "string" && text.trim() ? text.trim() : null;
    })
    .filter((t): t is string => t !== null);

  const payload: PayloadAppConfig = {
    splashBackgroundUrl,
    emptyStateAvatarUrls,
    gradientPresets,
    paywallProFeatures,
  };
  appConfigCache = { expiresAt: now + CACHE_TTL_MS, payload };
  return payload;
}

// ---------------------------------------------------------------------------
// Hair / Clothes / Face presets — CMS-gestuurde preset-collecties (E33+).
// Elke rij is één chip/kaart in het paneel. De `prompt` zit in het type maar
// wordt NIET geëxporteerd naar de client — alleen /v1/stylize gebruikt hem.
// ---------------------------------------------------------------------------

export type PayloadHairPreset = { key: string; label: string; prompt: string; thumbnailUrl: string | null; order: number };
export type PayloadClothesPreset = { key: string; label: string; prompt: string; thumbnailUrl: string | null; order: number };
export type PayloadFacePreset = { key: string; label: string; prompt: string; thumbnailUrl: string | null; order: number };

type PresetDoc = { key: string; label: string; prompt: string; thumbnailUrl: string | null; order: number };

let hairCache: { expiresAt: number; payload: PayloadHairPreset[] } | null = null;
let clothesCache: { expiresAt: number; payload: PayloadClothesPreset[] } | null = null;
let faceCache: { expiresAt: number; payload: PayloadFacePreset[] } | null = null;

function normalizePreset(raw: unknown): PresetDoc | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const key = typeof r.key === "string" ? r.key.trim() : null;
  const prompt = typeof r.prompt === "string" ? r.prompt.trim() : null;
  if (!key || !prompt) return null;
  const label = typeof r.label === "string" && r.label.trim() ? r.label.trim() : key;
  // E52.1: optionele CMS-thumbnail (upload-referentie, resolved via depth=1).
  // Collecties zonder thumbnail-veld leveren gewoon `null` — geen schema-eis.
  const thumb = r.thumbnail as { url?: string } | null | undefined;
  const thumbnailUrl = thumb && typeof thumb.url === "string" ? thumb.url : null;
  const order = typeof r.order === "number" ? r.order : 99;
  return { key, label, prompt, thumbnailUrl, order };
}

async function fetchPresets(
  slug: string,
  cache: { expiresAt: number; payload: unknown[] } | null,
  setCache: (c: { expiresAt: number; payload: unknown[] }) => void,
): Promise<PresetDoc[]> {
  const now = Date.now();
  if (cache && cache.expiresAt > now) {
    return cache.payload as PresetDoc[];
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn(`PAYLOAD_API_URL/KEY missing — ${slug} disabled`);
    return [];
  }
  const url = new URL(`${base}/${slug}`);
  url.searchParams.set("limit", "100");
  // depth=1 (E52.1): resolve een eventuele thumbnail-upload → { url }.
  url.searchParams.set("depth", "1");
  url.searchParams.set("where[active][equals]", "true");
  url.searchParams.set("sort", "order");
  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error(`Payload ${slug} fetch failed`, res.status, await res.text().catch(() => ""));
    return [];
  }
  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const presets = docs.map(normalizePreset).filter((p): p is PresetDoc => p !== null);
  setCache({ expiresAt: now + CACHE_TTL_MS, payload: presets });
  return presets;
}

export async function fetchActiveHairPresets(): Promise<PayloadHairPreset[]> {
  return fetchPresets("hair-presets", hairCache, (c) => {
    hairCache = c as { expiresAt: number; payload: PayloadHairPreset[] };
  });
}

export async function fetchActiveClothesPresets(): Promise<PayloadClothesPreset[]> {
  return fetchPresets("clothes-presets", clothesCache, (c) => {
    clothesCache = c as { expiresAt: number; payload: PayloadClothesPreset[] };
  });
}

export async function fetchActiveFacePresets(): Promise<PayloadFacePreset[]> {
  return fetchPresets("face-presets", faceCache, (c) => {
    faceCache = c as { expiresAt: number; payload: PayloadFacePreset[] };
  });
}

// ---------------------------------------------------------------------------
// Feature flags — singleton Global in Payload (E33+). Alle flags default
// naar `true` zodat de app nooit kapot gaat bij een CMS-storing.
// ---------------------------------------------------------------------------

export type PayloadFeatureFlags = {
  effectsEnabled: boolean;
  hairEnabled: boolean;
  clothesEnabled: boolean;
  faceEnabled: boolean;
  backgroundsEnabled: boolean;
};

const FEATURE_FLAGS_DEFAULT: PayloadFeatureFlags = {
  effectsEnabled: true,
  hairEnabled: true,
  clothesEnabled: true,
  faceEnabled: true,
  backgroundsEnabled: true,
};

let featureFlagsCache: { expiresAt: number; payload: PayloadFeatureFlags } | null = null;

export async function fetchFeatureFlags(): Promise<PayloadFeatureFlags> {
  const now = Date.now();
  if (featureFlagsCache && featureFlagsCache.expiresAt > now) {
    return featureFlagsCache.payload;
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL/KEY missing — feature-flags defaulting to all enabled");
    return FEATURE_FLAGS_DEFAULT;
  }
  const url = new URL(`${base}/globals/feature-flags`);
  url.searchParams.set("depth", "0");
  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload feature-flags fetch failed", res.status, await res.text().catch(() => ""));
    return FEATURE_FLAGS_DEFAULT;
  }
  const doc = (await res.json()) as Record<string, unknown>;
  const flag = (name: string) => (doc[name] === false ? false : true);
  const payload: PayloadFeatureFlags = {
    effectsEnabled: flag("effectsEnabled"),
    hairEnabled: flag("hairEnabled"),
    clothesEnabled: flag("clothesEnabled"),
    faceEnabled: flag("faceEnabled"),
    backgroundsEnabled: flag("backgroundsEnabled"),
  };
  featureFlagsCache = { expiresAt: now + CACHE_TTL_MS, payload };
  return payload;
}

// ---------------------------------------------------------------------------
// E17.2 — Messages (verenigd model, slug "messages"). Naast de announcement-
// functies hierboven; niet-destructief. Spiegelt admin/src/collections/
// Messages.ts: kanaal + targeting-group + schedule-group + body/image/cta.
// ---------------------------------------------------------------------------

export type PayloadMessage = {
  slug: string;
  title: string;
  channel: "inApp" | "email" | "both";
  body: string;
  imageUrl: string | null;
  cta: { label: string; url: string } | null;
  // schedule (flat)
  frequency: "once" | "everySignInUntilDismissed" | "untilDate" | "delayedNthSignIn";
  untilDate: string | null;
  delayN: number | null;
  publishedAt: string | null;
  expiresAt: string | null;
  // targeting (flat)
  cohort: "all" | "freeUsers" | "proUsers" | "specificEmails";
  audienceEmails: string[];
  signupAfter: string | null;
  signupBefore: string | null;
  minAppVersion: string | null;
  /// Bovengrens (inclusief) — E13.8: bereik alléén 2.0.0/2.0.1-installs.
  maxAppVersion: string | null;
  platform: "all" | "macos";
};

let messageCache: { expiresAt: number; payload: PayloadMessage[] } | null = null;

export async function fetchPublishedMessages(): Promise<PayloadMessage[]> {
  const now = Date.now();
  if (messageCache && messageCache.expiresAt > now) {
    return messageCache.payload;
  }
  const base = payloadBase();
  if (!base || !PAYLOAD_API_KEY) {
    console.warn("PAYLOAD_API_URL invalid / PAYLOAD_API_KEY missing — messages disabled");
    return [];
  }

  const url = new URL(`${base}/messages`);
  url.searchParams.set("limit", "100");
  url.searchParams.set("depth", "1");
  // publishedAt leeft onder de schedule-group → dot-notation in de where.
  url.searchParams.set("where[schedule.publishedAt][exists]", "true");
  url.searchParams.set("where[schedule.publishedAt][less_than_equal]", new Date().toISOString());

  const res = await fetch(url, {
    headers: { Authorization: `users API-Key ${PAYLOAD_API_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) {
    console.error("Payload messages fetch failed", res.status, await res.text().catch(() => ""));
    return [];
  }
  const json = (await res.json()) as { docs?: unknown[] };
  const docs = Array.isArray(json.docs) ? json.docs : [];
  const messages = docs.map(normalizeMessage).filter((m): m is PayloadMessage => m !== null);
  messageCache = { expiresAt: now + CACHE_TTL_MS, payload: messages };
  return messages;
}

function normalizeMessage(raw: unknown): PayloadMessage | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const slug = typeof r.slug === "string" ? r.slug : null;
  const title = typeof r.title === "string" ? r.title : null;
  if (!slug || !title) return null;

  const channel = (() => {
    const c = r.channel;
    return c === "inApp" || c === "email" || c === "both" ? c : "inApp";
  })();

  const image = r.image as { url?: string } | null | undefined;
  const imageUrl = image && typeof image.url === "string" ? image.url : null;

  const cta = (() => {
    const c = r.primaryCta as { label?: string; url?: string } | null | undefined;
    if (!c || typeof c.label !== "string" || typeof c.url !== "string") return null;
    if (!c.label.trim() || !c.url.trim()) return null;
    return { label: c.label, url: c.url };
  })();

  const schedule = (r.schedule as Record<string, unknown>) ?? {};
  const frequency = (() => {
    const f = schedule.frequency;
    if (f === "once" || f === "everySignInUntilDismissed" || f === "untilDate" || f === "delayedNthSignIn") return f;
    return "once";
  })();

  const targeting = (r.targeting as Record<string, unknown>) ?? {};
  const cohort = (() => {
    const a = targeting.cohort;
    if (a === "all" || a === "freeUsers" || a === "proUsers" || a === "specificEmails") return a;
    return "all";
  })();
  const audienceEmails = Array.isArray(targeting.audienceEmails)
    ? (targeting.audienceEmails as unknown[])
        .map((e) => (typeof e === "object" && e !== null ? (e as { email?: string }).email : e))
        .filter((e): e is string => typeof e === "string" && e.trim().length > 0)
        .map((e) => e.trim().toLowerCase())
    : [];
  const platform = targeting.platform === "macos" ? "macos" : "all";

  const str = (v: unknown): string | null => (typeof v === "string" ? v : null);

  return {
    slug,
    title,
    channel,
    body: lexicalToMarkdown(r.body),
    imageUrl,
    cta,
    frequency,
    untilDate: str(schedule.untilDate),
    delayN: typeof schedule.delayN === "number" ? schedule.delayN : null,
    publishedAt: str(schedule.publishedAt),
    expiresAt: str(schedule.expiresAt),
    cohort,
    audienceEmails,
    signupAfter: str(targeting.signupAfter),
    signupBefore: str(targeting.signupBefore),
    minAppVersion: str(targeting.minAppVersion),
    maxAppVersion: (() => {
      const v = str(targeting.maxAppVersion);
      return v && v.trim() ? v.trim() : null;
    })(),
    platform,
  };
}

/**
 * Best-effort semver compare — returns true if `version >= min`. Falls
 * back to "true" on anything unparseable so a typo in `minAppVersion`
 * never blocks an announcement entirely.
 */
/**
 * Counterpart of `meetsMinVersion` — true if `version <= max`. A client
 * without a version header passes: the only clients that omit it are 1.x
 * installs, which is exactly who a max-gated announcement is for.
 */
export function withinMaxVersion(version: string | null, max: string | null): boolean {
  if (!max) return true;
  if (!version) return true;
  const parse = (s: string) => s.split(".").map((p) => parseInt(p, 10) || 0);
  const v = parse(version);
  const m = parse(max);
  for (let i = 0; i < Math.max(v.length, m.length); i++) {
    const a = v[i] ?? 0;
    const b = m[i] ?? 0;
    if (a < b) return true;
    if (a > b) return false;
  }
  return true;
}

export function meetsMinVersion(version: string | null, min: string | null): boolean {
  if (!min) return true;
  if (!version) return false;
  const parse = (s: string) => s.split(".").map((p) => parseInt(p, 10) || 0);
  const v = parse(version);
  const m = parse(min);
  for (let i = 0; i < Math.max(v.length, m.length); i++) {
    const a = v[i] ?? 0;
    const b = m[i] ?? 0;
    if (a > b) return true;
    if (a < b) return false;
  }
  return true;
}
