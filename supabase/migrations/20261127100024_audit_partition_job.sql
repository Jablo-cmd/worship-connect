-- M-024: keep audit partitions ahead of time. Uses pg_cron where available (verified available on Supabase, spike S-1).
-- If pg_cron is unavailable in an environment this migration is a no-op and an external scheduler must call
-- private.ensure_audit_partitions(3) daily. CI asserts partitions exist for the next 3 months regardless (test CAT-21).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('audit-partitions', '17 3 * * *', 'select private.ensure_audit_partitions(3)');
  else
    raise notice 'pg_cron not available: schedule private.ensure_audit_partitions(3) externally';
  end if;
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end $$;
