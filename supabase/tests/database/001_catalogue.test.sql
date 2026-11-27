-- CAT-*: structural security guarantees, asserted from the catalogue (DATABASE_TESTING_STRATEGY.md 3.1).
-- Run with `supabase test db` (pgTAP). Fails fast and loudly: these are release-gate checks.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- server-only tables: RLS on, NO policy, NO grants to client roles
create temp table server_only (schema_name text, table_name text);
insert into server_only values ('public','invitation_tokens'),('platform','admins'),('platform','support_access_grants'),
  ('platform','takedown_requests'),('platform','organisation_status_log');

-- CAT-01 RLS enabled and forced on every table in public and platform
select is((select count(*) from pg_tables where schemaname in ('public','platform') and not rowsecurity), 0::bigint, 'CAT-01 every public/platform table has RLS enabled');
select is((select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','platform') and c.relkind in ('r','p') and not c.relforcerowsecurity), 0::bigint, 'CAT-01b every table, INCLUDING audit partitions, has FORCE RLS (a partition queried directly does not inherit the parent policies)');

-- CAT-02 every public table has at least one policy, or is server-only with zero client privileges
select is((select count(*) from pg_tables t where t.schemaname='public' and not exists (select 1 from pg_policies p where p.schemaname='public' and p.tablename=t.tablename)
           and not exists (select 1 from server_only s where s.schema_name=t.schemaname and s.table_name=t.tablename) and t.tablename not like 'audit_events_%'), 0::bigint,
          'CAT-02 every public table has a policy unless it is server-only');
select is((select count(*) from server_only s where has_any_column_privilege('authenticated', format('%I.%I', s.schema_name, s.table_name), 'select,insert,update,references')
           or has_any_column_privilege('anon', format('%I.%I', s.schema_name, s.table_name), 'select,insert,update,references')), 0::bigint, 'CAT-02b server-only tables have no client privileges');
select is((select count(*) from pg_policies p join server_only s on s.schema_name=p.schemaname and s.table_name=p.tablename), 0::bigint, 'CAT-02c server-only tables have no policies');

-- CAT-03 anon holds nothing
-- (M-025: the GLOBAL default EXECUTE-to-PUBLIC must be revoked; a schema-scoped ALTER DEFAULT PRIVILEGES cannot remove it)
select is((select count(*) from information_schema.role_table_grants where grantee='anon' and table_schema in ('public','private','platform')), 0::bigint, 'CAT-03 anon has no table privileges');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private','platform') and has_function_privilege('anon', p.oid, 'execute')), 0::bigint, 'CAT-03b anon cannot execute any function in public/private/platform');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private','platform') and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)), 0::bigint, 'CAT-03c no function is executable by PUBLIC');
select is((select count(*) from information_schema.role_usage_grants where grantee='anon' and object_schema in ('private','platform')), 0::bigint, 'CAT-03d anon has no usage on private/platform');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('private','platform') and p.prorettype = 'trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute')), 0::bigint, 'CAT-03e trigger functions are not executable by clients');

-- CAT-04 authenticated has no platform access and no write access to append-only/ledger tables
select is((select count(*) from information_schema.role_table_grants where grantee='authenticated' and table_schema='platform'), 0::bigint, 'CAT-04 authenticated has no privileges on platform tables');
select is((select count(*) from information_schema.role_table_grants where grantee='authenticated' and table_schema='public' and table_name in ('audit_events','membership_status_events','policy_acceptances') and privilege_type in ('UPDATE','DELETE','TRUNCATE')), 0::bigint, 'CAT-04b no UPDATE/DELETE/TRUNCATE on append-only tables');

-- CAT-05 every SECURITY DEFINER function pins an empty search_path
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private','platform') and p.prosecdef
           and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c in ('search_path=""','search_path=')) ), 0::bigint, 'CAT-05 every SECURITY DEFINER function has search_path = ''''');
-- trigger functions that read other tables are also definer-hardened; plain trigger functions must still pin search_path
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')), 0::bigint, 'CAT-05b every function in private pins search_path');
-- CAT-06 identity is never a parameter of a definer function
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef
           and exists (select 1 from unnest(coalesce(p.proargnames,'{}')) a where a ~* '^(p_)?(user|user_id|uid|auth_uid|role_name|caller)$')), 0::bigint, 'CAT-06 no definer function takes a caller-identity parameter');

-- CAT-07 tenant tables expose (organisation_id, id) as a unique target for composite foreign keys
select is((select count(*) from information_schema.columns c where c.table_schema='public' and c.column_name='organisation_id'
           and c.table_name not in ('audit_events','invitation_tokens','invitation_teams','membership_contacts','organisation_settings','roles','membership_status_events','policy_acceptances')   -- append-only / 1:1 leaf tables nothing references
           and c.table_name not like 'audit_events_%'
           and not exists (select 1 from pg_index i join pg_class t on t.oid=i.indrelid join pg_namespace n on n.oid=t.relnamespace
                           where n.nspname='public' and t.relname=c.table_name and i.indisunique
                             and (select array_agg(a.attname::text order by a.attname::text) from pg_attribute a where a.attrelid=t.oid and a.attnum = any(i.indkey)) = array['id','organisation_id'])), 0::bigint,
          'CAT-07 every tenant table has UNIQUE (organisation_id, id)');

-- CAT-08 foreign keys between tenant tables are composite and include organisation_id
select is((select count(*) from pg_constraint k join pg_class t on t.oid=k.conrelid join pg_class r on r.oid=k.confrelid
           join pg_namespace tn on tn.oid=t.relnamespace join pg_namespace rn on rn.oid=r.relnamespace
           where k.contype='f' and tn.nspname='public' and rn.nspname='public' and r.relname not in ('organisations','roles','profiles','permissions')
             and exists (select 1 from pg_attribute a where a.attrelid=r.oid and a.attname='organisation_id' and not a.attisdropped)
             and not exists (select 1 from pg_attribute a where a.attrelid=t.oid and a.attnum = any(k.conkey) and a.attname='organisation_id')), 0::bigint,
          'CAT-08 every foreign key to a tenant table includes organisation_id');

-- CAT-09 the foreign-key graph is acyclic (self references excepted)
with recursive edges as (
  select k.conrelid as src, k.confrelid as dst from pg_constraint k join pg_namespace n on n.oid=k.connamespace where k.contype='f' and n.nspname in ('public','platform') and k.conrelid <> k.confrelid),
walk as (select src, dst, array[src] as path from edges union all select w.src, e.dst, w.path || e.src from walk w join edges e on e.src = w.dst where not e.src = any(w.path))
select is((select count(*) from walk where src = dst), 0::bigint, 'CAT-09 no foreign-key cycles');

-- CAT-10 every foreign key has a supporting NON-PARTIAL index (or a partial one whose predicate is `col IS NOT NULL`).
-- Accepted layouts: (a) the key's columns are the leading columns in any order, e.g. (organisation_id, parent_id);
-- (b) the first non-organisation key column leads. Audit-style actor columns are exempt.
select is((select count(*) from pg_constraint k join pg_class t on t.oid=k.conrelid join pg_namespace n on n.oid=t.relnamespace
           where k.contype='f' and n.nspname='public' and t.relkind in ('r','p')
             and not exists (select 1 from pg_index i join pg_attribute a0 on a0.attrelid=i.indrelid and a0.attnum=i.indkey[0]
                             where i.indrelid=t.oid
                               and ( (i.indkey::int2[])[0:cardinality(k.conkey)-1] @> k.conkey::int2[] and cardinality(k.conkey) <= array_length(i.indkey::int2[],1)
                                     or a0.attname = (select a.attname from pg_attribute a where a.attrelid=t.oid and a.attnum = any(k.conkey) order by (a.attname='organisation_id'), a.attnum limit 1) )
                               and (i.indpred is null or pg_get_expr(i.indpred, i.indrelid) ~ '^\(?[a-z_]+ IS NOT NULL\)?$'))
             and not exists (select 1 from pg_attribute a where a.attrelid=t.oid and a.attnum = any(k.conkey) and a.attname ~ '(assigned_by|revoked_by|added_by|accepted_membership|accepted_by|created_by|logo_file|avatar_file|actor)')), 0::bigint,
          'CAT-10 foreign keys are indexed (actor/audit columns exempt)');

-- CAT-11 views are security invoker
select is((select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v' and not coalesce((select option_value='true' from pg_options_to_table(c.reloptions) where option_name='security_invoker'), false)), 0::bigint, 'CAT-11 every public view is security_invoker');
select is((select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='m'), 0::bigint, 'CAT-11b no materialised views in public (they cannot enforce RLS)');

-- CAT-12 permission keys used in policies and function bodies exist in the catalogue
create temp table used_keys as
  select distinct (m)[1] as k from (select regexp_matches(coalesce(qual,'') || ' ' || coalesce(with_check,''), '''([a-z_]+\.[a-z_]+)''', 'g') m from pg_policies where schemaname='public') s
  union
  select distinct (m)[1] from (select regexp_matches(p.prosrc, 'has_perm[a-z_]*\([^)]*''([a-z_]+\.[a-z_]+)''', 'g') m from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private')) s;
select is((select count(*) from used_keys u where u.k ~ '^(org|structure|teams|locations|members|availability|onboarding|roles|music|services|rehearsals|attendance|tasks|announcements|channels|messages|meetings|production|equipment|reports|audit|files)\.' and not exists (select 1 from public.permissions p where p.key=u.k)), 0::bigint, 'CAT-12 every permission key referenced by a policy/function exists');

-- CAT-13 INSERT and UPDATE policies carry an explicit WITH CHECK
select is((select count(*) from pg_policies where schemaname='public' and cmd in ('INSERT','UPDATE','ALL') and with_check is null), 0::bigint, 'CAT-13 every INSERT/UPDATE policy has WITH CHECK');

-- CAT-14 organisation_id is immutable (forbid_org_change) on every client-updatable tenant table
select is((select count(*) from information_schema.columns c where c.table_schema='public' and c.column_name='organisation_id'
           and c.table_name not in ('audit_events','invitation_tokens','invitation_teams','roles','membership_status_events','policy_acceptances','organisations') and c.table_name not like 'audit_events_%'
           and not exists (select 1 from pg_trigger g join pg_proc f on f.oid=g.tgfoid join pg_class t on t.oid=g.tgrelid where t.relname=c.table_name and f.proname='forbid_org_change' and not g.tgisinternal)), 0::bigint, 'CAT-14 organisation_id is immutable on every tenant table');

-- CAT-15 append-only tables are protected by the block-mutation trigger
select is((select count(*) from (values ('public','audit_events'),('public','membership_status_events'),('public','policy_acceptances'),('platform','organisation_status_log')) v(s,t)
           where not exists (select 1 from pg_trigger g join pg_proc f on f.oid=g.tgfoid where g.tgrelid=format('%I.%I', v.s, v.t)::regclass and f.proname='block_mutation' and not g.tgisinternal)), 0::bigint, 'CAT-15 append-only tables have the block-mutation trigger');

-- CAT-16 no secret-looking column is readable by clients (audit_events.client_ip_hash is a keyed hash of an IP, readable by audit.view by design)
select is((select count(*) from pg_attribute a join pg_class t on t.oid = a.attrelid join pg_namespace n on n.oid = t.relnamespace
           where n.nspname = 'public' and t.relkind in ('r','p','v') and a.attnum > 0 and not a.attisdropped
             and a.attname ~ '(hash|secret|token|password)' and a.attname <> 'client_ip_hash'
             and not exists (select 1 from pg_depend d where d.objid = t.oid and d.deptype = 'e')      -- ignore objects that belong to extensions (e.g. pgTAP installed in public by the CLI)
             and has_column_privilege('authenticated', t.oid, a.attnum, 'select')), 0::bigint, 'CAT-16 no secret-like column is selectable by authenticated');

-- CAT-17 naming conventions
select is((select count(*) from information_schema.columns where table_schema in ('public','platform') and (column_name !~ '^[a-z][a-z0-9_]*$')), 0::bigint, 'CAT-17 columns are lower_snake_case');
select is((select count(*) from information_schema.tables where table_schema in ('public','platform') and table_type='BASE TABLE' and table_name !~ '^[a-z][a-z0-9_]*$'), 0::bigint, 'CAT-17b tables are lower_snake_case');

-- CAT-20 time-zone validator is an allow-list
select is(private.is_valid_timezone('Africa/Johannesburg') and private.is_valid_timezone('Australia/Lord_Howe') and private.is_valid_timezone('UTC'), true, 'CAT-20 accepts real IANA zones');
select is((select count(*) from unnest(array['EST','UTC+3','Factory','Etc/GMT+5','posix/Europe/London','Not/AZone','']) z where private.is_valid_timezone(z)) + case when private.is_valid_timezone(null) then 1 else 0 end, 0::bigint, 'CAT-20b rejects abbreviations, POSIX strings, Etc/, posix/, unknown, empty and NULL');

-- CAT-21 audit partitions exist ahead of time and the DEFAULT partition is empty
select is((select count(*) from generate_series(0,3) i where to_regclass('public.audit_events_' || to_char(date_trunc('month', now()) + make_interval(months => i), 'YYYY_MM')) is null), 0::bigint, 'CAT-21 audit partitions exist for the next 3 months');
select is((select count(*) from public.audit_events_default), 0::bigint, 'CAT-21b the DEFAULT audit partition is empty (alert condition)');

-- seed integrity (also MTX-01 in the API suite)
select is((select count(*) from public.permissions), 45::bigint, 'seed: 45 permissions');
select is((select count(*) from public.roles where is_system), 8::bigint, 'seed: 8 system roles');
select is((select count(*) from public.role_permissions), 194::bigint, 'seed: 194 role-permission pairs');
select is((select count(*) from public.role_permissions rp join public.permissions p on p.key = rp.permission_key join public.roles r on r.id = rp.role_id where r.system_key <> 'owner' and rp.permission_key = 'org.ownership.manage'), 0::bigint, 'seed: only Owner holds org.ownership.manage');
select is((select count(*) from public.roles r where r.is_system and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id)), 0::bigint, 'seed: every system role has permissions');

select * from finish();
rollback;
