import { createClient, SupabaseClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL!;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY!;

if (!url || !serviceRoleKey) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set");
}

/**
 * Server-side Supabase client using the service role key.
 * NEVER send this key to the browser or the app — it bypasses RLS.
 */
export const supabase: SupabaseClient = createClient(url, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export type SubscriptionRow = {
  id: string;
  user_id: string;
  tier: "starter" | "plus" | "studio";
  status: string;
  monthly_credits: number;
  current_period_start: string;
  current_period_end: string;
  cancel_at_period_end: boolean;
};

/** Returns the user's active subscription (if any). */
export async function activeSubscription(userId: string): Promise<SubscriptionRow | null> {
  const { data, error } = await supabase
    .from("subscriptions")
    .select("*")
    .eq("user_id", userId)
    .in("status", ["active", "trialing", "past_due"])
    .order("current_period_end", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return (data as SubscriptionRow | null) ?? null;
}

/** Returns remaining credits for the user's current period (0 if none). */
export async function currentCredits(userId: string): Promise<number> {
  const { data, error } = await supabase.rpc("current_credits", { p_user: userId });
  if (error) throw error;
  return typeof data === "number" ? data : 0;
}

/** Inserts a ledger entry. `delta` is positive for grants, negative for spends. */
export async function logCredit(opts: {
  userId: string;
  delta: number;
  reason: string;
  ref?: string;
}): Promise<void> {
  const { error } = await supabase.from("credit_ledger").insert({
    user_id: opts.userId,
    delta: opts.delta,
    reason: opts.reason,
    ref: opts.ref ?? null,
  });
  if (error) throw error;
}

/** Ensures a `public.users` row exists (mirrors auth.users). */
export async function ensureUser(userId: string): Promise<void> {
  const { error } = await supabase
    .from("users")
    .upsert({ id: userId }, { onConflict: "id" });
  if (error) throw error;
}
