import type { VercelRequest, VercelResponse } from "@vercel/node";
import type Stripe from "stripe";
import { stripe, creditsForTier, tierFromPriceId, type Tier } from "../lib/stripe.js";
import { supabase } from "../lib/supabase.js";

// Stripe webhook signature verification requires the raw request body.
export const config = {
  api: {
    bodyParser: false,
  },
};

async function readRaw(req: VercelRequest): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

async function findUserByCustomerId(customerId: string): Promise<string | null> {
  const { data } = await supabase
    .from("users")
    .select("id")
    .eq("stripe_customer_id", customerId)
    .maybeSingle();
  return (data?.id as string | undefined) ?? null;
}

async function upsertSubscription(sub: Stripe.Subscription, userId: string) {
  const priceId = sub.items.data[0]?.price.id;
  const tier: Tier | null = tierFromPriceId(priceId);
  if (!tier) {
    console.warn("Unknown price ID on subscription", priceId);
    return;
  }
  await supabase.from("subscriptions").upsert(
    {
      id: sub.id,
      user_id: userId,
      tier,
      status: sub.status,
      monthly_credits: creditsForTier(tier),
      current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
      current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
      cancel_at_period_end: sub.cancel_at_period_end,
    },
    { onConflict: "id" },
  );
}

async function grantPeriodCredits(opts: {
  userId: string;
  tier: Tier;
  invoiceId: string;
}) {
  // Idempotent: the ref column has a unique index in SQL, so a retry on the
  // same invoice will violate and be ignored.
  const { error } = await supabase.from("credit_ledger").insert({
    user_id: opts.userId,
    delta: creditsForTier(opts.tier),
    reason: "period_renewal",
    ref: opts.invoiceId,
  });
  if (error && !/duplicate key/i.test(error.message)) {
    throw error;
  }
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const sig = req.headers["stripe-signature"];
  if (!sig || typeof sig !== "string") {
    res.status(400).json({ error: "Missing signature" });
    return;
  }

  const raw = await readRaw(req);
  const secret = process.env.STRIPE_WEBHOOK_SECRET!;

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(raw, sig, secret);
  } catch (err) {
    console.error("Invalid Stripe signature", err);
    res.status(400).json({ error: "Invalid signature" });
    return;
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId = session.metadata?.supabase_user_id;
        const customerId = typeof session.customer === "string" ? session.customer : session.customer?.id;
        if (userId && customerId) {
          await supabase
            .from("users")
            .upsert({ id: userId, stripe_customer_id: customerId }, { onConflict: "id" });
        }
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
        const userId =
          (sub.metadata?.supabase_user_id as string | undefined) ??
          (await findUserByCustomerId(customerId));
        if (!userId) {
          console.warn("No user found for subscription", sub.id);
          break;
        }
        await upsertSubscription(sub, userId);
        break;
      }

      case "invoice.paid": {
        const invoice = event.data.object as Stripe.Invoice;
        const customerId = typeof invoice.customer === "string" ? invoice.customer : invoice.customer?.id;
        if (!customerId) break;
        const userId = await findUserByCustomerId(customerId);
        if (!userId) break;

        const priceId = invoice.lines.data[0]?.price?.id;
        const tier = tierFromPriceId(priceId);
        if (!tier) break;

        await grantPeriodCredits({
          userId,
          tier,
          invoiceId: invoice.id,
        });
        break;
      }

      default:
        // Unhandled event types are fine — just ack.
        break;
    }

    res.status(200).json({ received: true });
  } catch (err) {
    console.error("stripe-webhook handler error", err);
    res.status(500).json({ error: "Webhook handler failed" });
  }
}
