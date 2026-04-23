import Stripe from "stripe";

export const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: "2025-02-24.acacia",
});

export type Tier = "starter" | "plus" | "studio";

const PRICE_IDS: Record<Tier, string> = {
  starter: process.env.PRICE_ID_STARTER!,
  plus: process.env.PRICE_ID_PLUS!,
  studio: process.env.PRICE_ID_STUDIO!,
};

const CREDITS_PER_TIER: Record<Tier, number> = {
  starter: 20,
  plus: 50,
  studio: 150,
};

export function priceIdForTier(tier: Tier): string {
  return PRICE_IDS[tier];
}

export function creditsForTier(tier: Tier): number {
  return CREDITS_PER_TIER[tier];
}

/**
 * Maps a Stripe price ID back to a Tier. Used by the webhook handler when
 * processing `subscription.created/updated` events.
 */
export function tierFromPriceId(priceId: string | undefined | null): Tier | null {
  if (!priceId) return null;
  for (const t of Object.keys(PRICE_IDS) as Tier[]) {
    if (PRICE_IDS[t] === priceId) return t;
  }
  return null;
}
