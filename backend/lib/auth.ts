import { jwtVerify } from "jose";
import type { VercelRequest, VercelResponse } from "@vercel/node";

const secret = new TextEncoder().encode(process.env.SUPABASE_JWT_SECRET!);

export type AuthedUser = {
  id: string;
  email?: string;
};

/**
 * Verifies the `Authorization: Bearer <jwt>` header against Supabase's JWT
 * secret (HS256). Returns the user on success; sends a 401 and returns null
 * on failure.
 */
export async function requireUser(
  req: VercelRequest,
  res: VercelResponse,
): Promise<AuthedUser | null> {
  const header = req.headers.authorization ?? "";
  const m = header.match(/^Bearer\s+(.+)$/i);
  if (!m) {
    res.status(401).json({ error: "Missing Authorization header" });
    return null;
  }
  try {
    const { payload } = await jwtVerify(m[1], secret, { algorithms: ["HS256"] });
    const sub = typeof payload.sub === "string" ? payload.sub : null;
    if (!sub) {
      res.status(401).json({ error: "Invalid token" });
      return null;
    }
    const email = typeof payload.email === "string" ? payload.email : undefined;
    return { id: sub, email };
  } catch {
    res.status(401).json({ error: "Invalid or expired token" });
    return null;
  }
}

/** Simple per-user token bucket for rate limiting. In-memory; resets on cold start. */
const bucket = new Map<string, { tokens: number; lastRefill: number }>();
const REFILL_PER_SECOND = 0.5; // 1 request per 2 seconds
const BUCKET_SIZE = 3;

export function checkRateLimit(userId: string): boolean {
  const now = Date.now();
  const entry = bucket.get(userId) ?? { tokens: BUCKET_SIZE, lastRefill: now };
  const elapsed = (now - entry.lastRefill) / 1000;
  entry.tokens = Math.min(BUCKET_SIZE, entry.tokens + elapsed * REFILL_PER_SECOND);
  entry.lastRefill = now;
  if (entry.tokens < 1) {
    bucket.set(userId, entry);
    return false;
  }
  entry.tokens -= 1;
  bucket.set(userId, entry);
  return true;
}
