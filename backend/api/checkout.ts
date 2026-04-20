import type { VercelRequest, VercelResponse } from "@vercel/node";
import { requireUser } from "../lib/auth.js";
import { ensureUser, supabase } from "../lib/supabase.js";
import { priceIdForTier, stripe, type Tier } from "../lib/stripe.js";

const APP_SCHEME = process.env.APP_URL_SCHEME ?? "aaavatar";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  const user = await requireUser(req, res);
  if (!user) return;

  const tier = (req.body?.tier ?? "") as Tier;
  if (!["starter", "plus", "studio"].includes(tier)) {
    res.status(400).json({ error: "Invalid tier" });
    return;
  }

  try {
    await ensureUser(user.id);

    // Reuse an existing Stripe customer if we've created one.
    const { data: existing } = await supabase
      .from("users")
      .select("stripe_customer_id")
      .eq("id", user.id)
      .maybeSingle();

    let customerId = existing?.stripe_customer_id as string | null | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email,
        metadata: { supabase_user_id: user.id },
      });
      customerId = customer.id;
      await supabase
        .from("users")
        .update({ stripe_customer_id: customerId })
        .eq("id", user.id);
    }

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: priceIdForTier(tier), quantity: 1 }],
      success_url: `${APP_SCHEME}://stripe-return`,
      cancel_url: `${APP_SCHEME}://stripe-cancel`,
      allow_promotion_codes: true,
      automatic_tax: { enabled: true },
      subscription_data: {
        metadata: { supabase_user_id: user.id, tier },
      },
      metadata: { supabase_user_id: user.id, tier },
    });

    res.status(200).json({ url: session.url });
  } catch (err) {
    console.error("/api/checkout error", err);
    res.status(500).json({ error: "Checkout failed" });
  }
}
