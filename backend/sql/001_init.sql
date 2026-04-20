-- Avatars API — initial schema.
-- Run in the Supabase SQL editor. `auth.users` is managed by Supabase Auth.

create extension if not exists pgcrypto;

-- 1. App users (1:1 with Supabase auth.users).
create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  stripe_customer_id text unique,
  created_at timestamptz not null default now()
);

-- 2. Active subscription per user. Keyed by Stripe subscription id so
-- webhook upserts are idempotent.
create table if not exists public.subscriptions (
  id text primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  tier text not null check (tier in ('starter', 'plus', 'studio')),
  status text not null,
  monthly_credits int not null,
  current_period_start timestamptz not null,
  current_period_end timestamptz not null,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists subscriptions_user_idx on public.subscriptions (user_id);

-- 3. Credit ledger — the source of truth. Balance = SUM(delta) within the
-- active period. Immutable: inserts only, never updates.
create table if not exists public.credit_ledger (
  id bigserial primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  delta int not null,                           -- + grant, - spend
  reason text not null,                         -- 'period_renewal' | 'extend_body' | 'refund' | 'initial_grant'
  ref text,                                     -- stripe invoice id or replicate prediction id
  created_at timestamptz not null default now()
);

create index if not exists credit_ledger_user_created_idx
  on public.credit_ledger (user_id, created_at desc);

-- Webhook retries may replay the same invoice.paid event. Enforce idempotency
-- on period grants: (reason, ref) uniquely identifies a renewal insert.
create unique index if not exists credit_ledger_reason_ref_unique
  on public.credit_ledger (reason, ref)
  where ref is not null and reason = 'period_renewal';

-- 4. Balance helper — returns credits for the user's current period.
create or replace function public.current_credits(p_user uuid)
returns int
language sql
stable
as $$
  select coalesce(sum(l.delta), 0)::int
  from public.credit_ledger l
  left join public.subscriptions s on s.user_id = l.user_id
  where l.user_id = p_user
    and (s.current_period_start is null or l.created_at >= s.current_period_start);
$$;

-- 5. Row-level security: everything locked down — server uses service role.
alter table public.users enable row level security;
alter table public.subscriptions enable row level security;
alter table public.credit_ledger enable row level security;

-- (No policies defined — clients cannot read these tables directly. All
-- reads/writes go through Vercel functions using the service role key.)
