# Worship Connect

**A complete operating platform for worship ministries.**

Worship Connect is a multi-tenant SaaS platform for churches to organise people, prepare music, coordinate services, manage rehearsals, operate technical production and communicate in one shared workspace.

## Product promise

**One place to organise people, prepare music, coordinate services and manage worship ministry operations.**

## Product goals

- Centralise worship ministry operations and communication.
- Improve service planning, music preparation and scheduling.
- Give every member a personalised view of assignments and commitments.
- Coordinate worship, choir, band, audio, lighting, media and production teams.
- Help leaders identify operational issues before service day.
- Protect church data through tenant isolation and server-enforced permissions.

## Documentation

- [Product requirements](docs/PRODUCT_REQUIREMENTS.md)
- [Technical architecture](docs/TECHNICAL_ARCHITECTURE.md)
- [Domain model](docs/DOMAIN_MODEL.md)
- [Security and privacy](docs/SECURITY_AND_PRIVACY.md)
- [User workflows](docs/USER_WORKFLOWS.md)
- [Delivery roadmap](docs/ROADMAP.md)
- [Architecture decisions](docs/DECISIONS.md)

### Database specification (proposed — not yet approved or implemented)

- [Database architecture](docs/DATABASE_ARCHITECTURE.md) — findings, principles, decisions, risks, requirement traceability
- [Database schema](docs/DATABASE_SCHEMA.md) — table inventory, columns, constraints, indexes, timestamps and deletion policy
- [RLS security specification](docs/RLS_SECURITY_SPECIFICATION.md) — privileges, helper functions, per-table policies, storage and realtime
- [Permissions matrix](docs/PERMISSIONS_MATRIX.md) — permission catalogue, system roles and role/permission matrix
- [Database migration plan](docs/DATABASE_MIGRATION_PLAN.md) — phased migrations, ordering and dependencies
- [Database testing strategy](docs/DATABASE_TESTING_STRATEGY.md) — automated tenant-isolation and security tests

## Database foundation (Phase 1) — development and testing

The Phase 1 database (identity, tenancy, roles, invitations, files registry, audit, platform schema) lives in
`supabase/migrations/` and is verified by an automated security suite. **Nothing here is production-deployed.**

```bash
npm ci
supabase start && supabase db reset        # local stack; applies migrations + synthetic seed (supabase/seed.sql)
supabase test db                           # pgTAP: catalogue + trigger tests (supabase/tests/database)
eval "$(supabase status -o env | sed 's/^/export /')"
SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" npm test   # API suite, real JWTs
npm run check:matrix                       # permission seed must match docs/PERMISSIONS_MATRIX.md
```

- Tests build two churches through the real API and need a clean tenant state. On a persistent dev database run
  `scripts/reset-test-data.sql` first (it refuses to run if any non-test user exists).
- `supabase/seed.sql` creates **synthetic** users and must never be run against production.
- The service-role key is used by test fixtures only (to play the file scanner). It must never appear in browser code,
  `NEXT_PUBLIC_*` variables or any committed file. See `.env.example`.
- Never edit an applied migration: add a new one. Permission/role seed changes: edit the matrix, run
  `python3 scripts/generate-permissions-seed.py`, and add a corrective migration for deployed databases.

## Initial technology direction

Next.js, TypeScript, Supabase Auth, PostgreSQL, Row Level Security, Supabase Realtime, Supabase Storage, Tailwind CSS, shadcn/ui and Vercel. These are proposed choices and must be validated for compatibility, limits and cost before production.

## Project status

- **Stage:** Product definition and architecture
- **Implementation:** Not yet started
- **Specification:** Initial baseline; subject to validation

Documentation describes intended behaviour; it does not mean functionality or security controls have already been implemented.

## Development principles

1. Design for multi-tenancy from the beginning.
2. Enforce authorisation at server and database boundaries, never only in the UI.
3. Keep tenant data isolated.
4. Use migrations for database changes.
5. Test tenant isolation before onboarding real churches.
6. Build complete workflows rather than disconnected screens.
7. Keep the experience responsive and accessible.
8. Document significant architectural decisions.
9. Avoid unnecessary dependencies and scope changes.
10. Never commit secrets or real sensitive test data.

The working product name is **Worship Connect**, matching the repository. Final brand identity remains open.
