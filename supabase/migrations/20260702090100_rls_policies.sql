-- Beer Game — Row Level Security (Vercel + Supabase migration, Phase 1).
-- Translates firestore.rules into RLS (see CLAUDE.md §5).
--
-- Model:
--   * READS are allowed from the client (required for Supabase Realtime).
--   * WRITES are DENIED to anon/authenticated: every mutation goes through a
--     server endpoint using the service role, which bypasses RLS entirely.
--     Hence there are SELECT policies only — no INSERT/UPDATE/DELETE policies.
--
-- Helper functions are SECURITY DEFINER so they can read profiles/games without
-- tripping the very policies that call them (avoids RLS infinite recursion).

-- current user is an approved admin
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'admin'
      and p.status = 'approved'
  );
$$;

-- current user is an approved instructor (or admin)
create or replace function public.is_approved_instructor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.status = 'approved'
      and p.role in ('admin', 'instructor')
  );
$$;

-- current user may MANAGE the game (owner or admin)
create or replace function public.can_manage_game(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1 from public.games g
    where g.code = p_code
      and g.owner_instructor_id = auth.uid()
  );
$$;

-- current user may READ the game (owner, admin, or publicly readable:
-- valid status + not expired) — mirrors isPublicGameReadable in firestore.rules
create or replace function public.can_read_game(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.games g
    where g.code = p_code
      and (
        public.is_admin()
        or g.owner_instructor_id = auth.uid()
        or (g.status in ('lobby', 'in_progress', 'ended') and g.expires_at > now())
      )
  );
$$;

-- Enable RLS everywhere.
alter table public.profiles     enable row level security;
alter table public.games        enable row level security;
alter table public.teams        enable row level security;
alter table public.players      enable row level security;
alter table public.player_names enable row level security;
alter table public.rate_limits  enable row level security;
alter table public.email_quota  enable row level security;

-- Explicit privileges (defense in depth; RLS still filters on top).
grant select on public.games, public.players, public.teams to anon, authenticated;
grant select on public.profiles, public.player_names to authenticated;
-- Server-only tables: no client access at all.
revoke all on public.rate_limits, public.email_quota from anon, authenticated;

-- profiles: read your own row; admins read all. No client writes.
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

-- games: readable by owner / admin / publicly (valid + not expired).
create policy games_select on public.games
  for select to anon, authenticated
  using (public.can_read_game(code));

-- players / teams: readable whenever the parent game is readable.
create policy players_select on public.players
  for select to anon, authenticated
  using (public.can_read_game(game_code));

create policy teams_select on public.teams
  for select to anon, authenticated
  using (public.can_read_game(game_code));

-- player_names: only the owner/admin can read (matches firestore.rules).
create policy player_names_select on public.player_names
  for select to authenticated
  using (public.can_manage_game(game_code));

-- rate_limits & email_quota: RLS enabled, zero policies, no grants => fully
-- inaccessible to clients. Only the service role (which bypasses RLS) touches them.
