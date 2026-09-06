import type { VercelRequest, VercelResponse } from "@vercel/node";
import { requireUser } from "../../lib/auth.js";
import { proOverrideFor } from "../../lib/proAccess.js";
import { activeSubscription, supabase } from "../../lib/supabase.js";
import { fetchPublishedMessages, meetsMinVersion, withinMaxVersion } from "../../lib/payload.js";

/**
 * GET /v1/messages (E17.2)
 *
 * Returns the in-app messages (channel inApp|both) the signed-in user is
 * targeted by and hasn't dismissed, after cohort / signup-date / app-version
 * / platform / expiry filters. The macOS app (MessagingService, E17.3) reads
 * this on sign-in / after first cutout and queues them.
 *
 * Response: { messages: [{ slug, title, body, imageUrl, cta, frequency }] }
 * Headers: Authorization: Bearer <token> (required); X-App-Version (optional).
 *
 * Niet-destructief naast /v1/announcements/pending: aparte collectie
 * ("messages"), hergebruikt de `announcement_seen`-tabel voor dismiss-state
 * (slugs zijn uniek per publisher). Faalt nooit luid — CMS-outage → lege lijst.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  const user = await requireUser(req, res);
  if (!user) return;

  try {
    const messages = await fetchPublishedMessages();
    if (messages.length === 0) {
      res.status(200).json({ messages: [] });
      return;
    }

    const appVersion = headerString(req.headers["x-app-version"]);
    const now = new Date();

    const sub = await activeSubscription(user.id);
    // Comped/dev accounts (E14.9) count as Pro for cohort targeting — they see
    // the app as a Pro sees it, so "proUsers" copy is the copy that applies.
    const isPro =
      (sub !== null && (sub.status === "active" || sub.status === "trialing")) ||
      (await proOverrideFor(user.email)) !== null;

    // Signup-datum voor cohort-targeting (best-effort; public.users.created_at).
    const userCreatedAt = await fetchUserCreatedAt(user.id);

    // Dismiss-state (gedeelde tabel met announcements).
    const { data: seenRows } = await supabase
      .from("announcement_seen")
      .select("slug")
      .eq("user_id", user.id);
    const seenSlugs = new Set((seenRows ?? []).map((r) => (r as { slug: string }).slug));

    const email = (user.email ?? "").toLowerCase();
    const out: unknown[] = [];

    for (const m of messages) {
      // Alleen in-app-kanaal in deze feed (email-only gaat via dispatch).
      if (m.channel === "email") continue;
      // Expiry.
      if (m.expiresAt && new Date(m.expiresAt) < now) continue;
      if (m.frequency === "untilDate" && m.untilDate && new Date(m.untilDate) < now) continue;
      // Cohort.
      if (m.cohort === "freeUsers" && isPro) continue;
      if (m.cohort === "proUsers" && !isPro) continue;
      if (m.cohort === "specificEmails" && !m.audienceEmails.includes(email)) continue;
      // Signup-datum (alleen filteren als we de datum kennen).
      if (userCreatedAt) {
        if (m.signupAfter && userCreatedAt < new Date(m.signupAfter)) continue;
        if (m.signupBefore && userCreatedAt > new Date(m.signupBefore)) continue;
      }
      // Platform (client is macOS).
      if (m.platform !== "all" && m.platform !== "macos") continue;
      // App-versie. max = E13.8: een "installeer de DMG opnieuw"-bericht
      // alléén voor 2.0.0/2.0.1 (die kunnen niet via Sparkle updaten).
      if (!meetsMinVersion(appVersion, m.minAppVersion)) continue;
      if (!withinMaxVersion(appVersion, m.maxAppVersion)) continue;
      // Dismissed.
      if (seenSlugs.has(m.slug)) continue;

      out.push({
        slug: m.slug,
        title: m.title,
        body: m.body,
        imageUrl: m.imageUrl,
        cta: m.cta,
        frequency: m.frequency,
      });
    }

    res.status(200).json({ messages: out });
  } catch (err) {
    console.error("/v1/messages error", err);
    res.status(200).json({ messages: [] });
  }
}

async function fetchUserCreatedAt(userId: string): Promise<Date | null> {
  try {
    const { data } = await supabase
      .from("users")
      .select("created_at")
      .eq("id", userId)
      .maybeSingle();
    const raw = (data as { created_at?: string } | null)?.created_at;
    return raw ? new Date(raw) : null;
  } catch {
    return null;
  }
}

function headerString(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
