# `backend/sql/` — schema, migrations, data classification

Every Postgres-side change is a numbered `.sql` migration applied
manually in the Supabase SQL editor. The numbering is strictly linear;
do not branch or skip numbers.

## Migration order

| # | File | What it does | Depends on |
|---|---|---|---|
| 001 | `001_init.sql` | Core schema: `users`, `subscriptions`, `credit_ledger`, `current_credits()` | — |
| 002 | `002_v1_extensions.sql` | Top-up support (`reason='topup_pack'` unique index) | 001 |
| 003 | `003_free_cutouts.sql` | `device_imports` + free-cutout counter helper | 001 |
| 004 | `004_free_imports.sql` | Free-import counters (account + device) + `try_consume_free_import()` | 001, 003 |
| 005 | `005_device_grants.sql` | Pre-auth checkout: `device_grants` table | 001 |
| 006 | `006_cutout_uploads_bucket.sql` | Supabase Storage bucket + policies | — |
| 007 | `007_lint_security_fixes.sql` | RLS on `device_imports` / `device_grants`; pinned `search_path` on helpers | 001, 004, 005 |
| 008 | `008_payload_scoped_role.sql` | `payload_app` Postgres role for the admin (audit CRITICAL #1) | — |
| 009 | `009_current_credits_fix.sql` | `current_credits()` handles multi-active subs correctly (audit MEDIUM #18) | 001, 007 |
| 010 | `010_newsletter_cohorts_view.sql` | Materialised view + refresh function so admin doesn't need service role (audit HIGH #12) | 001, 008 |
| 011 | `011_free_import_counter_merge.sql` | Account/device counter merge on sign-in (audit MEDIUM #19) | 001, 004, 007 |
| 013 | `013_newsletter_cohorts_revoke_public.sql` | Revoke anon/authenticated grants on cohort view + refresh fn (linter ERROR) | 010 |
| 014 | `014_newsletter_double_optin.sql` | Double-opt-in ledger for Nieuwsbrief 2.0 (E17.6) — gated, additive | 010 |
| 014 | `014_generated_results_bucket.sql` | Storage bucket `generated-results` for /v1/generate-background signed-URL delivery (E42) — ⚠️ duplicate number with the double-opt-in migration (both idempotent; apply both) | — |
| 015 | `015_custom_effects.sql` | User-created custom Effects (E34): table + storage | 001, 006 |
| 016 | `016_refund_e43_generate_background_outage.sql` | **One-off ops script, not schema**: credit-refund for the E43/A2 generate-background outage. Dry-run first; refund block is commented out — run only after sign-off | 001 |
| 017 | `017_payload_effects_style_references.sql` | `payload.effects_style_references` array table for CMS style references on Effects (E54.1) — apply BEFORE the admin deploy that ships the field | 008 |
| 018 | `018_pro_access.sql` | `payload.pro_access` (CMS-managed Pro list, E14.9) + `credit_ledger` idempotency index for the monthly comp grant — apply BEFORE the admin/backend deploy | 001, 002, 008 |
| 019 | `019_payload_messages_banner_presets_catchup.sql` | Catch-up DDL for `payload.messages` + `payload.banner_presets` (E17/E39) that never reached prod in the push:true era — applied 2026-08-03 (E55 roll-out) | 008 |
| 020 | `020_atomic_credit_spend.sql` | Race-safe credit spend for paid generation endpoints (E56) | 001, 002 |
| 021 | `021_announcements_max_app_version.sql` | `payload.announcements.max_app_version` for 1.x-only announcements (the "Aaavatar 2 is out" notice) — apply BEFORE the admin deploy that ships the field (the 2.0.0 `main` push) | 008 |
| 022 | `022_credit_buckets.sql` | Two-bucket `current_credits()` (E14.12): the monthly grant refills at renewal, `topup_pack` credits never expire; ledger-only, no `subscriptions` window. Built-in self-check + pre-flight diff query (run section 1 → pre-flight → section 2) — applied 2026-09-04 | 001, 002, 020 |
| 023 | `023_messages_max_app_version.sql` | `payload.messages.targeting_max_app_version` (E13.8): version cap on in-app messages so a "reinstall the DMG" notice reaches only 2.0.0/2.0.1 (no Sparkle sandbox entitlements) and never 2.0.2+ — apply BEFORE the admin deploy that ships the field | 019 |

## Data classification

Each row carries the highest-applicable tier — when in doubt, round up.
References the tier definitions in [`docs/security/policy.md`](../../docs/security/policy.md#2-classification).

### `public` schema

| Table / view | Tier | Notes |
|---|---|---|
| `users` (1:1 with `auth.users`) | **PII + payment** | Stores `stripe_customer_id` linking the user to billing records. Service-role only. |
| `subscriptions` | **payment** | Stripe subscription metadata. Retained for 7 years (Dutch tax law) even after account deletion — see right-to-erasure endpoint comments. |
| `credit_ledger` | **payment** | Append-only ledger of credit grants / spends. `ref` carries Stripe invoice IDs / Replicate prediction IDs. Balance = fold into two buckets (022): `period_renewal` refills the monthly bucket, `topup_pack` never expires, spends drain monthly first. Same 7-year retention as `subscriptions`. |
| `device_imports` | **PII (low)** | Per-device fingerprint UUID + free-import counter. Pseudonymous; fingerprint is a UserDefaults UUID, not hardware-derived. |
| `device_grants` | **PII** | Maps device fingerprint → `user_id` for pre-auth checkout. Carries the same sensitivity as `users` because the linkage is direct. |
| `device_user_merges` | **PII (low)** | Junction tracking which (device, user) pairs have had counters merged. Pseudonymous unless joined to `users`. |
| `newsletter_cohorts` (materialised view) | **PII** | Email + tier. Refreshed by SECURITY DEFINER function callable by the scoped `payload_app` role. |

### `auth` schema (Supabase-owned)

| Table | Tier | Notes |
|---|---|---|
| `auth.users` | **PII** | Supabase-managed. Accessed by the backend via GoTrue admin API only (PostgREST blocks the schema for direct queries). |

### `payload` schema (admin CMS)

Owned by the `payload_app` Postgres role per migration 008. The schema
is auto-managed by Payload's Drizzle adapter; ownership is documented
in [`admin/README.md`](../../admin/README.md#database-role-scoped-payload_app).

| Collection | Tier | Notes |
|---|---|---|
| `users` (admin operators) | **PII** | Single-operator at the moment. MFA-gated. |
| `announcements`, `badge-components`, `media` | **public** | Drives in-app announcements + NEW badges. No PII. |
| `newsletter-unsubscribes` | **PII** | Email addresses that opted out. Retained even after account deletion so a re-signup doesn't accidentally re-send. |
| `pro-access` | **PII** | Email addresses granted Pro without payment (E14.9), plus a free-text note about who they are. Writes are admin-session-only; the backend's API key has read access. |

### Storage buckets

| Bucket | Tier | Notes |
|---|---|---|
| `cutout-uploads` | **PII** | User-uploaded portraits for Magic Cutout. Per-user prefix. 5-min signed URLs. Best-effort cleanup after each cutout; aggressive `DELETE /v1/account` sweep on account deletion. |
| `announcement-media` (Payload) | **public** | Hero images + CTA images shipped in announcements. |

## Retention summary

- **Auth + ledger + subscriptions**: 7 years for the records linked to
  Stripe invoices (Dutch tax law); shorter for `users.created_at` rows
  that were never billed (deleted on right-to-erasure).
- **`cutout-uploads`**: best-effort wiped immediately after each cutout;
  fully swept on right-to-erasure (`DELETE /v1/account`).
- **Newsletter cohorts (materialised view)**: refreshed on demand; never
  stored beyond the most-recent refresh.
- **`newsletter-unsubscribes`**: kept indefinitely (audit HIGH #15 — a
  user who opted out should stay opted out).

## RLS posture

All tables in `public` have RLS enabled (migrations 001 and 007). No
client policies are defined — every read/write goes through Vercel
functions using either the service role (RLS-bypass) or the scoped
`payload_app` role (no `public` access).
