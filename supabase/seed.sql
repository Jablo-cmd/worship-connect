-- SYNTHETIC TEST USERS. LOCAL / CI / DEV ONLY - this file is applied by `supabase db reset` and must NEVER be run against
-- production (migrations are the only thing deployed to production). Fixed UUIDs make tests deterministic.
-- The shared password is a public test value, not a secret.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.name || '@wc-test.example',
       extensions.crypt('Wc-Test-Password-1!', extensions.gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('display_name', initcap(u.name)), now(), now(), '', '', '', ''
from (values
  ('alice',   'aaaaaaaa-0000-4000-8000-000000000001'::uuid), ('bob',    'aaaaaaaa-0000-4000-8000-000000000002'::uuid),
  ('carol',   'aaaaaaaa-0000-4000-8000-000000000003'::uuid), ('dan',    'aaaaaaaa-0000-4000-8000-000000000004'::uuid),
  ('dora',    'aaaaaaaa-0000-4000-8000-000000000005'::uuid), ('erin',   'aaaaaaaa-0000-4000-8000-000000000006'::uuid),
  ('felix',   'aaaaaaaa-0000-4000-8000-000000000007'::uuid), ('grace',  'aaaaaaaa-0000-4000-8000-000000000008'::uuid),
  ('heidi',   'aaaaaaaa-0000-4000-8000-000000000009'::uuid), ('ivan',   'aaaaaaaa-0000-4000-8000-000000000010'::uuid),
  ('judy',    'aaaaaaaa-0000-4000-8000-000000000011'::uuid), ('mallory','aaaaaaaa-0000-4000-8000-000000000012'::uuid),
  ('nora',    'aaaaaaaa-0000-4000-8000-000000000013'::uuid)
) as u (name, id)
on conflict (id) do nothing;

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), 'email', now(), now(), now()
from auth.users u where u.email like '%@wc-test.example'
on conflict do nothing;
