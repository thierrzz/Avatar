import type { VercelRequest, VercelResponse } from "@vercel/node";
import { requireUser } from "../lib/auth.js";
import { activeSubscription, currentCredits, ensureUser } from "../lib/supabase.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  const user = await requireUser(req, res);
  if (!user) return;

  try {
    await ensureUser(user.id);
    const [sub, credits] = await Promise.all([
      activeSubscription(user.id),
      currentCredits(user.id),
    ]);

    res.status(200).json({
      tier: sub?.tier ?? null,
      status: sub?.status ?? null,
      credits,
      renewsAt: sub?.current_period_end ?? null,
      cancelAtPeriodEnd: sub?.cancel_at_period_end ?? false,
      email: user.email ?? null,
    });
  } catch (err) {
    console.error("/api/me error", err);
    res.status(500).json({ error: "Internal error" });
  }
}
