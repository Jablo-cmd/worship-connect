# Worship Connect — Database Runbooks

Operational procedures for the production Supabase project. Each runbook states a trigger, steps and a verification. Nothing here has been
exercised against a production project yet; **the first drill of each procedure is part of the go-live gate** (`PRODUCTION_READINESS.md`).

Conventions: the production project is separate from `worship-hub` (dev). Secrets live only in the platform's secret store and the
GitHub `production` Environment; never in the repo, chat or browser code. The service-role key is server-side only.

## 1. Release a migration
1. Merge to `main` with the `database` CI job green (pgTAP + API suite on a fresh local stack).
2. Run the **deploy-production** workflow (manual). It checks the target is not the dev project, requires the project ref to be typed,
   needs an Environment reviewer's approval, runs `supabase db push --dry-run`, then applies.
3. Verify: `supabase migration list` shows the new version; run security + performance advisors (§7); smoke-test sign-in and `my_workspaces`.
4. Migrations are **forward-only**. A bad migration is fixed by a new corrective migration (as M-025…M-030 were), never by editing history.
   For data-destroying changes take a manual backup first (§2) and use expand → migrate → contract.

## 2. Backups and restore drill
- Enable daily backups and **Point-in-Time Recovery** (paid plan) on production. Record the retention window and RPO/RTO targets here once chosen.
- **Drill (before go-live, then quarterly):** restore the latest backup/PITR point into a *new* scratch project; run the pgTAP catalogue
  checks and `select count(*)` sanity queries; confirm RLS is enabled on every table and `anon` has no table/function access; delete the scratch project.
- Record: date, backup used, time to restore, issues found. A backup that has never been restored is not a backup.

## 3. Suspected tenant-isolation breach (highest severity)
1. Contain: if a specific organisation or user is implicated, suspend via the platform console functions (instant lock-out — status is evaluated live).
   If the cause is a policy/function defect, disable the affected API surface (revoke `execute` on the RPC from `authenticated`) in an emergency migration.
2. Preserve: do not truncate or edit `audit_events`; export the relevant partitions. Note time window and actors.
3. Assess scope from `audit_events` and Supabase API/Postgres logs: which tenants, tables, rows.
4. Fix with a corrective migration + a regression test in `tests/integration` (and a catalogue assertion where structural). Release per §1.
5. Notify affected organisations per the legal/privacy process (decision D-040 — open). Post-mortem within 5 working days.

## 4. Key and secret rotation
- **Service-role / secret API key:** create the new key, update every server-side consumer, then revoke the old key. Verify no 401s in logs.
- **Publishable (anon) key:** public by design; rotate only if abused.
- **JWT signing key:** rotate via the Supabase signing-keys flow; expect all sessions to re-authenticate if a legacy secret is rolled.
- **Database password:** rotate in the dashboard, then update `SUPABASE_DB_PASSWORD` in the production Environment.
- **GitHub secrets** (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_REF`): rotate on staff change. Drill once before go-live.
- If a secret may have leaked (gitleaks hit, screenshot, chat paste): treat as compromised — rotate first, investigate second.

## 5. Audit partition health
`audit_events` is partitioned monthly; `private.ensure_audit_partitions(3)` runs daily via pg_cron (M-024).
- Alert if rows land in `audit_events_default` (`select count(*) from public.audit_events_default` > 0) or if no partition exists for next month.
- Fix: run `select private.ensure_audit_partitions(3);`, then move default-partition rows into the correct partition in a maintenance window.
- Retention = detach/drop whole partitions after the period set by D-033 (open); never `delete` from `audit_events`.

## 6. Lock-out and offboarding
- Member suspension/removal: `set_membership_status` (effective on the same session, no re-login). Verify by listing that member's rows return 0.
- Organisation suspension: platform console function; all members lose access immediately.
- Right-to-erasure: `erase_my_account()` is **not yet implemented** (see PRODUCTION_READINESS.md); until it ships, handle requests manually with a reviewed script and record each in the audit log.

## 7. Post-release checks
- Supabase advisors: **0 security ERRORs**; review warnings. Known accepted items are tracked in `PRODUCTION_READINESS.md`.
- Catalogue: `supabase test db` equivalent run against a restored copy or staging; RLS on every public table; no secret-like column readable by `authenticated`.
- Alerts firing correctly (§5), auth error rates normal, p95 API latency within target.

## 8. Contacts and escalation
To be completed before go-live: on-call owner, backup owner, Supabase support plan/contact, legal/privacy contact for breach notification.
