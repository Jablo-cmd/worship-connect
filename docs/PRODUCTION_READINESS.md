# Worship Connect — Production Readiness Gate

Honest status of the Phase 1 database foundation against a production launch. **Verdict today: not production-ready** — the engineering
foundation is verified in CI, but operational, legal and review gates below are open. Update this file as items close; do not tick an item without evidence.

Legend: ✅ done and verified · 🟡 done in repo, needs environment action · ⬜ open · 🔒 needs a human/legal decision

## A. Engineering (in repo)
| # | Item | Status | Evidence / note |
|---|------|--------|-----------------|
| A1 | Schema, RLS, RPCs, audit, storage and realtime policies for Phase 1 | ✅ | 24 migrations; applies from scratch in CI |
| A2 | Automated security tests (pgTAP catalogue + 31 function tests; 121 API tests on real JWTs) | ✅ | `database` CI job green on PR #4 |
| A3 | Permission matrix generated from docs, drift-checked in CI | ✅ | `npm run check:matrix` |
| A4 | Secret scanning in CI | ✅ | gitleaks, full history |
| A5 | Manual, approval-gated production deploy workflow; never seeds or runs tests on production | 🟡 | `.github/workflows/deploy-production.yml`; needs `production` Environment with reviewers + 3 secrets |
| A6 | Parallel double-accept of one invitation test | ⬜ | needs a concurrency test with two sessions |
| A7 | Signed-URL expiry / `Cache-Control` tests | ⬜ | |
| A8 | Malware scanner + service-side file finalisation | ⬜ | no file becomes `available` without a service-role actor today |
| A9 | `erase_my_account()` | ⬜ | design in DATABASE_ARCHITECTURE.md §6 (anonymise, keep audit) — blocked on D-033/D-040 retention/legal wording |
| A10 | Retention/purge jobs (files, messages, attendance, exports, closed orgs) | ⬜ | periods are open decisions (D-017/D-033) |
| A11 | Phase 2+ tables (services, rehearsals, messaging, notifications, reports…) | ⬜ | product phases, not part of Phase 1 |
| A12 | Performance re-check at realistic volume on production-class hardware | ⬜ | spike S-4 was local only |

## B. Operations (environment)
| # | Item | Status |
|---|------|--------|
| B1 | Separate production Supabase project (not `worship-hub`) | ✅ `worship-connect-prod` (ref `vkgxsfnhjmolkntreoqo`, eu-west-2, Auris Nexus org) created 2026-11-28; all 24 migrations applied; verified against dev: 34 tables / 0 without RLS, 50 policies, 56 functions with identical definitions, 61 triggers, 133 indexes, anon executes 0 functions and holds 0 grants; security advisor: 0 errors (13 INFO RLS-no-policy = intended deny-all tables, 16 WARN = intended `authenticated` RPCs); 0 users/orgs (no demo or test data) |
| B2 | Backups + PITR enabled; **restore drill performed** (RUNBOOKS §2) | ⬜ |
| B3 | Monitoring/alerting: audit DEFAULT-partition, partition job, auth errors, 5xx, latency (RUNBOOKS §5) | ⬜ |
| B4 | Auth: leaked-password protection ON, email confirmation ON, production SMTP/templates, rate limits, CAPTCHA on sign-up/recovery | ⬜ |
| B5 | Edge rate limiting for sign-in, recovery and invitation endpoints | ⬜ |
| B6 | Key-rotation drill (RUNBOOKS §4) | ⬜ |
| B7 | Incident runbook rehearsed (tabletop of RUNBOOKS §3) | ⬜ |
| B8 | Data API exposes only `public` + `graphql_public` on production (verify in dashboard) | ⬜ (default for new projects; confirm in dashboard) |
| B9 | Dev project `worship-hub` kept separate; no production data in dev, no synthetic users in production | ✅ rule / ⬜ verify at launch |

## C. Assurance and legal
| # | Item | Status |
|---|------|--------|
| C1 | Independent review of every `SECURITY DEFINER` function and RLS policy | ⬜ |
| C2 | Penetration test: tenant isolation, invitations, storage, realtime | ⬜ |
| C3 | Legal decisions D-016 (age/minors), D-033 (retention), D-040 (breach notification), D-043 | 🔒 |
| C4 | Privacy policy / DPA / data-processing terms published | 🔒 |
| C5 | MFA | 🔒 deferred by decision D-027; `require_aal2()` hook is inert |

## Go-live rule
Production launch requires every A-item that is a security control (A1–A5, A7, A8) ✅, all B-items ✅, C1–C2 ✅ with findings closed, and C3–C4 resolved.
A9/A10 may follow launch only if no end-user data is collected before they ship (otherwise they are blockers).
