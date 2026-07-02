# Supabase (Phase 1 — Database & Auth)

This directory holds the Postgres schema, RLS policies, dev seed and tests for the
Vercel + Supabase migration (see `../CLAUDE.md` §4/§5/§8).

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/local-development) installed.
- Docker running (the local stack runs Postgres/Auth/Realtime in containers).

## Run locally

```bash
supabase start          # boots the local stack; applies migrations + seed.sql
supabase status         # shows local URLs + anon/service keys
supabase test db        # runs the pgTAP tests in ./tests
```

Reset the database (re-apply migrations + seed from scratch):

```bash
supabase db reset
```

## Layout

| Path | Purpose |
|---|---|
| `config.toml` | Local stack config. Enables email + **anonymous** sign-in; CAPTCHA block is commented (enable in cloud with a real secret). |
| `migrations/20260702090000_initial_schema.sql` | Tables, indexes, constraints (CLAUDE.md §4). |
| `migrations/20260702090100_rls_policies.sql` | RLS helpers + SELECT policies (CLAUDE.md §5). |
| `seed.sql` | **Local-dev only** admin: `admin@beergame.local` / `BeerGameAdmin!123`. |
| `tests/rls_test.sql` | pgTAP checks for the authorization model. |

## Authorization model (summary)

- **Reads** come from the client (needed for Realtime), gated by RLS:
  own profile / admin; games+players+teams by owner, admin, or public
  (valid status + not expired); `player_names` by owner/admin only.
- **Writes** are denied to clients — every mutation goes through a server
  endpoint with the **service role** (Phase 2). Hence SELECT-only policies.
- `rate_limits` / `email_quota` are server-only (no client grants).

## Linking to a cloud project (when ready)

```bash
supabase link --project-ref <your-project-ref>
supabase db push        # apply these migrations to the remote project
```
