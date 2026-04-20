# Avatars API — backend for the "Extend Body" Pro feature

Minimal Vercel + Supabase backend that:

1. Authenticates users via Supabase (Google OAuth hergebruikt uit de macOS app).
2. Handles Stripe Checkout + webhooks for three monthly tiers (Starter / Plus / Studio).
3. Tracks credits in Postgres (single source of truth: `credit_ledger`).
4. Proxies Replicate (`black-forest-labs/flux-fill-pro`) for outpainting.
5. Deducts one credit per successful extension.

## Stack

- **Runtime:** Vercel (Node.js functions — not Edge, because `sharp` is needed for mask generation)
- **DB + Auth:** Supabase (Postgres + built-in Google OAuth)
- **Payments:** Stripe Checkout + Customer Portal
- **AI:** Replicate `black-forest-labs/flux-fill-pro`

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/api/me` | Current tier + credits + renewal date |
| POST | `/api/checkout` | Create Stripe Checkout Session for a tier |
| POST | `/api/portal` | Stripe Customer Portal URL (upgrade / cancel) |
| POST | `/api/extend-body` | Run outpaint; deduct one credit |
| POST | `/api/stripe-webhook` | Stripe → Supabase sync (subscription, invoices) |

All user-facing endpoints expect an `Authorization: Bearer <supabase-jwt>` header.
`/api/stripe-webhook` is verified via the Stripe webhook signing secret.

## Setup

1. Create a Supabase project; enable Google OAuth provider. Set redirect URL to `aaavatar://auth-callback`.
2. Run the SQL in [`sql/001_init.sql`](sql/001_init.sql) via the Supabase SQL editor.
3. Create a Stripe account. In **test mode**, create three products (Starter / Plus / Studio) each with a monthly recurring EUR price (€4,99 / €9,99 / €19,99). Note the price IDs.
4. Create a webhook endpoint in Stripe pointing to `https://api.aaavatar.nl/api/stripe-webhook`. Subscribe to `checkout.session.completed`, `customer.subscription.created/updated/deleted`, `invoice.paid`.
5. Create a Replicate account and generate an API token with access to `black-forest-labs/flux-fill-pro`.
6. Copy [`.env.example`](.env.example) to `.env` and fill in secrets. Add the same keys in Vercel's project settings.
7. `npm install && vercel dev` voor lokaal testen; `vercel --prod` voor productie.

## Credit math

Replicate `flux-fill-pro` costs ≈ $0.04 per call. Per user per month, net margin:

| Tier    | Price (€) | Credits | Max cost (USD) | Margin (≈€) |
|---------|-----------|---------|-----------------|--------------|
| Starter | 4,99      | 20      | $0,80           | €3,24        |
| Plus    | 9,99      | 50      | $2,00           | €6,14        |
| Studio  | 19,99     | 150     | $6,00           | €10,98       |

(Subtracts ~19% VAT and ~3% Stripe fees. Credits reset monthly; unused credits expire.)

## Rate limiting

`/api/extend-body` enforces ~1 request / 2 seconds per user via an in-memory
token bucket (sufficient while Vercel keeps instances warm). For higher scale,
add Upstash or similar.
