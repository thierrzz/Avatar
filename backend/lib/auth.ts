import { createRemoteJWKSet, jwtVerify } from "jose";
import type { VercelRequest, VercelResponse } from "@vercel/node";

const SUPABASE_URL = process.env.SUPABASE_URL!;

// Supabase new-key architecture: access tokens are signed with an ECC P-256
// key published at /auth/v1/.well-known/jwks.json. Legacy HS256 JWT shared
// secret is intentionally not supported — project must have legacy JWT-based
// API keys disabled in Settings → API Keys.
const JWKS = createRemoteJWKSet(new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`));

export type AuthedUser = {
  id: string;
  email?: string;
};

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
  const token = m[1];

  const payload = await verifyToken(token);
  if (!payload) {
    res.status(401).json({ error: "Invalid or expired token" });
    return null;
  }
  const sub = typeof payload.sub === "string" ? payload.sub : null;
  if (!sub) {
    res.status(401).json({ error: "Invalid token" });
    return null;
  }
  const email = typeof payload.email === "string" ? payload.email : undefined;
  return { id: sub, email };
}

async function verifyToken(token: string) {
  try {
    const { payload } = await jwtVerify(token, JWKS);
    return payload;
  } catch {
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
