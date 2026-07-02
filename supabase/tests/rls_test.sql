-- Beer Game — RLS tests (pgTAP). Run with: `supabase test db`
-- Verifies the Phase 1 authorization model (CLAUDE.md §5): reads gated by
-- ownership/public-readability, server-only tables closed to clients.

begin;
select plan(16);

-- 1..7  RLS is enabled on every table
select ok((select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),     'RLS enabled: profiles');
select ok((select relrowsecurity from pg_class where oid = 'public.games'::regclass),        'RLS enabled: games');
select ok((select relrowsecurity from pg_class where oid = 'public.teams'::regclass),        'RLS enabled: teams');
select ok((select relrowsecurity from pg_class where oid = 'public.players'::regclass),      'RLS enabled: players');
select ok((select relrowsecurity from pg_class where oid = 'public.player_names'::regclass), 'RLS enabled: player_names');
select ok((select relrowsecurity from pg_class where oid = 'public.rate_limits'::regclass),  'RLS enabled: rate_limits');
select ok((select relrowsecurity from pg_class where oid = 'public.email_quota'::regclass),  'RLS enabled: email_quota');

-- 8..11  helper functions exist
select has_function('public', 'is_admin',               'is_admin() exists');
select has_function('public', 'is_approved_instructor', 'is_approved_instructor() exists');
select has_function('public', 'can_manage_game',        'can_manage_game() exists');
select has_function('public', 'can_read_game',          'can_read_game() exists');

-- 12..13  server-only tables are closed to clients
select ok(not has_table_privilege('anon', 'public.rate_limits', 'SELECT'),
          'anon has no SELECT on rate_limits');
select ok(not has_table_privilege('authenticated', 'public.email_quota', 'SELECT'),
          'authenticated has no SELECT on email_quota');

-- Fixtures (created as the superuser test role; RLS bypassed here).
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000001',
        'authenticated', 'authenticated', 'owner@test.local', now(), now(), '{}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.profiles (id, email, role, status)
values ('00000000-0000-0000-0000-000000000001', 'owner@test.local', 'instructor', 'approved')
on conflict (id) do nothing;

-- Codes obey the ^[A-Z2-9]{4,8}$ constraint (no 0/1 — matches the original
-- generateUniqueGameCode charset).
insert into public.games (code, status, owner_instructor_id, expires_at)
values ('PUBG', 'in_progress', '00000000-0000-0000-0000-000000000001', now() + interval '1 day'),
       ('EXPD', 'ended',       '00000000-0000-0000-0000-000000000001', now() - interval '1 day')
on conflict (code) do nothing;

-- 14..15  anonymous client: live game visible, expired game hidden
set local role anon;
select set_config('request.jwt.claims', null, true);
select is((select count(*)::int from public.games where code = 'PUBG'), 1,
          'anon can read a live (non-expired) game');
select is((select count(*)::int from public.games where code = 'EXPD'), 0,
          'anon cannot read an expired game');
reset role;

-- 16  owner sees their own game even after it expired
set local role authenticated;
select set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from public.games where code = 'EXPD'), 1,
          'owner reads own game regardless of expiry');
reset role;

select * from finish();
rollback;
