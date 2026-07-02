-- Beer Game — initial Postgres schema (Vercel + Supabase migration, Phase 1).
--
-- Translates the Firestore document model (see CLAUDE.md §4) into relational
-- tables. Per-role maps (stages / pendingOrders / ordersSubmitted) stay as jsonb
-- to minimise the delta with the existing game logic in src/logic/*.
--
-- What Firestore gave "for free" and how it is replaced here:
--   recursive delete of a session -> ON DELETE CASCADE on foreign keys
--   atomic counter increment       -> UPDATE ... SET x = x + 1 (server endpoints)
--   serverTimestamp()              -> default now()
--   name-uniqueness lock doc       -> UNIQUE (game_code, normalized_name)

create extension if not exists pgcrypto;

-- Keep updated_at fresh on UPDATE (used by server-only bookkeeping tables).
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- profiles: one row per authenticated instructor/admin (§4).
-- Role/status live here instead of Firebase custom claims (decision #4).
create table public.profiles (
  id                     uuid primary key references auth.users (id) on delete cascade,
  email                  text not null,
  name                   text not null default '',
  institution            text not null default '',
  country                text not null default '',
  role                   text not null default 'instructor'
                           check (role in ('admin', 'instructor')),
  status                 text not null default 'pending'
                           check (status in ('pending', 'approved', 'rejected', 'revoked')),
  email_verified         boolean not null default false,
  reviewed_by            uuid references auth.users (id) on delete set null,
  reviewed_at            timestamptz,
  created_at             timestamptz not null default now(),
  sessions_created_count integer not null default 0,
  players_joined_count   integer not null default 0
);
create index profiles_status_created_at_idx on public.profiles (status, created_at desc);

-- games: one session (§4). code is the 4-8 char join code (Firestore doc id).
create table public.games (
  code                  text primary key check (code ~ '^[A-Z2-9]{4,8}$'),
  status                text not null default 'lobby'
                          check (status in ('lobby', 'in_progress', 'ended')),
  owner_instructor_id   uuid not null references public.profiles (id) on delete cascade,
  owner_instructor_email text not null default '',
  config                jsonb not null default '{}'::jsonb,
  notes                 text not null default '',
  human_join_count      integer not null default 0,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null
);
create index games_owner_created_at_idx  on public.games (owner_instructor_id, created_at desc);
create index games_status_created_at_idx on public.games (status, created_at desc);
create index games_expires_at_idx        on public.games (expires_at);

-- teams: composite PK (game_code, id) mirrors the Firestore subcollection (§4).
create table public.teams (
  game_code        text not null references public.games (code) on delete cascade,
  id               text not null,
  name             text not null default '',
  current_week     integer not null default 1,
  human_count      integer not null default 0,
  stages           jsonb not null default '{}'::jsonb,
  pending_orders   jsonb not null default '{}'::jsonb,
  orders_submitted jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  primary key (game_code, id)
);

-- players (§4). team_id is a loose reference (nullable in lobby); kept without a
-- composite FK to mirror Firestore and avoid insert-ordering constraints.
create table public.players (
  id                 uuid primary key default gen_random_uuid(),
  game_code          text not null references public.games (code) on delete cascade,
  name               text not null,
  normalized_name    text not null,
  role               text check (role in ('retailer', 'wholesaler', 'distributor', 'factory')),
  team_id            text,
  is_robot           boolean not null default false,
  session_token_hash text,
  last_heartbeat_at  timestamptz,
  removed_at         timestamptz,
  removed_by         uuid,
  created_at         timestamptz not null default now()
);
create index players_game_code_idx       on public.players (game_code);
create index players_game_normalized_idx on public.players (game_code, normalized_name);

-- player_names: unique name lock per game (replaces the Firestore lock doc, §4).
create table public.player_names (
  game_code       text not null references public.games (code) on delete cascade,
  normalized_name text not null,
  player_id       uuid not null references public.players (id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (game_code, normalized_name)
);

-- rate_limits (§4) — server-only bookkeeping (App Check replacement, §7).
create table public.rate_limits (
  key          text primary key,
  count        integer not null default 0,
  window_start timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index rate_limits_updated_at_idx on public.rate_limits (updated_at);

-- email_quota (§4) — server-only daily email cap.
create table public.email_quota (
  day_key    text primary key,
  count      integer not null default 0,
  updated_at timestamptz not null default now()
);

create trigger rate_limits_set_updated_at
  before update on public.rate_limits
  for each row execute function public.set_updated_at();

create trigger email_quota_set_updated_at
  before update on public.email_quota
  for each row execute function public.set_updated_at();
