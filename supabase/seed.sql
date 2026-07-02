-- Beer Game — LOCAL DEV seed (Vercel + Supabase migration, Phase 1).
--
-- Seeds a development admin so RLS can be exercised right after `supabase start`.
-- In PRODUCTION the admin is bootstrapped at runtime by the
-- /api/admin/ensure-profile endpoint (see CLAUDE.md §6/§8) — do NOT rely on this
-- seed there.
--
-- Dev admin login:  admin@beergame.local  /  BeerGameAdmin!123
--
-- If your local GoTrue version rejects these auth.* inserts, create the admin via
-- Supabase Studio (Auth) or the CLI instead, then insert the matching profile row.

set search_path = public, extensions;

do $$
declare
  v_uid   uuid := '00000000-0000-0000-0000-0000000000ad';
  v_email text := 'admin@beergame.local';
begin
  -- auth user
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
  )
  values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    v_email, crypt('BeerGameAdmin!123', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  )
  on conflict (id) do nothing;

  -- email identity (required for email/password login on modern GoTrue)
  insert into auth.identities (
    provider_id, user_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  )
  values (
    v_uid::text, v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', v_email),
    'email', now(), now(), now()
  )
  on conflict do nothing;

  -- approved admin profile
  insert into public.profiles (
    id, email, name, role, status, email_verified, reviewed_by, reviewed_at
  )
  values (
    v_uid, v_email, 'Dev Admin', 'admin', 'approved', true, v_uid, now()
  )
  on conflict (id) do nothing;
end $$;
