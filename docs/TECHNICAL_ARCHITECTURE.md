# Worship Connect — Technical Architecture

**Version:** 1.0 | **Status:** Proposed architecture baseline

## 1. Goals

Secure multi-tenancy, multiple memberships per user, flexible organisation, server-enforced permissions, reliable realtime collaboration, maintainable modular code, safe migrations, predictable costs and a path to SaaS scale.

Start with a **modular monolith**, not microservices. Split services only when independent scaling or operations are justified by measured requirements.

## 2. Proposed stack

| Layer | Choice | Notes |
|---|---|---|
| Web | Next.js + TypeScript | App Router; server-first where practical |
| UI | Tailwind CSS + shadcn/ui | Accessible reusable components |
| Authentication | Supabase Auth | Identity and sessions |
| Database | Supabase PostgreSQL | Relational source of truth |
| Authorisation | RLS + server checks | Never frontend-only |
| Realtime | Supabase Realtime | Scoped events |
| Files | Supabase Storage | Private buckets and policies |
| Hosting | Vercel | Separate preview and production |
| Validation | Zod or equivalent | Validate external input |
| Testing | Vitest, Testing Library, Playwright | Unit, integration, E2E |

Validate current versions, provider limits, pricing and compatibility before implementation.

## 3. System view

```text
Browser (desktop/mobile)
        |
        v
Next.js application
  |-- Public and auth routes
  |-- Authenticated workspace
  |-- Server actions / route handlers
  |-- Domain services
        |
        v
Supabase
  |-- Auth
  |-- PostgreSQL + RLS
  |-- Realtime
  |-- Private Storage
        |
        v
Optional external providers
  |-- Email / push
  |-- Billing
  |-- AI
```

Wrap external providers behind internal interfaces where practical.

## 4. Suggested source layout

```text
src/
  app/
    (public)/
    (auth)/
    (platform)/
    (workspace)/
  components/
    ui/
    layout/
    shared/
  domains/
    identity/
    tenants/
    memberships/
    organisation/
    permissions/
    people/
    music/
    services/
    scheduling/
    rehearsals/
    communication/
    meetings/
    production/
    notifications/
    reporting/
  lib/
    supabase/
    auth/
    validation/
    permissions/
    errors/
  server/
    services/
    repositories/
  types/
  config/
supabase/
  migrations/
  seed/
  tests/
docs/
```

Organise by business domain; keep boundaries clear as the application grows.

## 5. Identity and tenant model

A global authenticated identity may have memberships in multiple church tenants. Each membership has its own status, roles and optional scope.

Every tenant-scoped request must establish:
1. Authenticated user identity.
2. Active membership in the requested tenant.
3. Permission for the action.
4. Resource scope (campus, ministry, department or team) where relevant.
5. Resource ownership and tenant relationship.

A selected workspace in the UI is convenience state, not an authorisation grant. Revalidate every request.

## 6. RBAC and scope

Roles are collections of stable permissions. Role assignments belong to tenant memberships and may be scoped to a campus, ministry, department or team. Platform roles are separate from church roles.

Example permission identifiers:
- tenant.settings.manage
- members.view / members.invite / members.manage
- roles.manage
- teams.manage
- music.view / music.manage
- services.view / services.create / services.publish
- assignments.manage
- rehearsals.manage
- attendance.record
- channels.manage
- messages.moderate
- meetings.manage
- production.manage
- reports.view

Centralise permission evaluation. Avoid scattered hardcoded role-name checks. Validate that role and scope resources belong to the same tenant.

## 7. Database principles

- UUID primary keys for application-owned entities.
- Foreign keys, unique constraints and check constraints.
- Explicit tenant ownership for tenant-owned records.
- Index common tenant-scoped filters and joins.
- Use timestamptz for instants.
- Store IANA timezone identifiers.
- Use controlled status values.
- Use created_at/updated_at and actor fields where useful.
- Use soft deletion only where retention and recovery justify it.
- Preserve published service history.
- Migrations are the authoritative schema history.

Do not use JSON as a substitute for relational modelling when data needs independent querying, permissions or constraints.

## 8. RLS and privileged operations

Enable RLS on every exposed tenant-owned table. Policies must derive tenant access from authenticated identity and active membership, and respect scope where required.

- Avoid recursive policy dependencies.
- Review SECURITY DEFINER functions and set a safe search_path.
- Revoke unnecessary execute privileges.
- Never expose service-role credentials to the browser.
- Privileged server operations must perform explicit authorisation before accessing data.
- Test using authenticated database sessions, not only service-role clients.

Service-role credentials bypass RLS and must be treated as highly sensitive.

## 9. Realtime

Use realtime for chat, presence where appropriate, notifications and selected service/assignment updates.

Realtime is a delivery mechanism, not the source of truth. Persist authoritative data in PostgreSQL. Scope topics and subscriptions by tenant and resource permissions. Handle reconnects, missed events and duplicate delivery.

## 10. File and media architecture

Private storage by default. Potential resources include charts, meeting documents, rehearsal recordings, service files, profile images and production diagrams.

- Tenant-aware object paths.
- Storage policies aligned with database permissions.
- Validate file size and MIME type.
- Short-lived signed URLs.
- Upload quotas and rate limits.
- Malware scanning strategy before broad sharing.
- Retention and deletion policy.
- Never rely on an obscure path as authorisation.

## 11. Time and scheduling

Store absolute instants in UTC using timestamptz and retain the relevant IANA timezone. Recurring schedules must preserve local wall-clock rules and handle daylight-saving transitions. Clearly show the church-local time and, where useful, the viewer's local time.

## 12. Notifications

Separate business event creation, preference evaluation, delivery and retry. Persist in-app notifications. Use asynchronous delivery for email/push when appropriate; do not make critical service-planning transactions depend on synchronous email delivery.

## 13. Auditability

Audit tenant creation/status, invitations, membership changes, role changes, sensitive settings, service publication/revisions, moderation, support access and exports. Record actor, tenant, action, target, timestamp and safe metadata. Never log credentials or unnecessary private content.

## 14. Environments and deployment

Maintain local, preview/test and production environments with separate database/auth/storage configuration and secrets.

- Document variables in .env.example without real values.
- No production secrets in Git.
- Review migrations before production.
- Prefer backward-compatible migrations.
- Preview must not use production personal data.
- Configure backups and test restoration.
- Protect production branch and high-risk changes.

## 15. Testing strategy

**Unit:** permission evaluation, domain rules, scheduling/timezone calculations and validation.

**Integration:** constraints, RLS, membership checks, storage and realtime authorisation.

**E2E:** registration, onboarding, workspace switching, invitations, roles, service planning and member responses.

Mandatory isolation matrix with at least two tenants:
- Tenant A member can access authorised A resources.
- A cannot read or mutate B resources.
- Non-member cannot access private tenant resources.
- Suspended/removed member loses access.
- A's role does not grant rights in B.
- Scoped leader cannot administer outside scope.
- Realtime and storage enforce equivalent boundaries.

## 16. Performance and cost

Paginate lists and messages; index observed query patterns; avoid unbounded realtime subscriptions; apply upload quotas and rate limits; monitor database, storage, egress and realtime usage. Cache only when permission boundaries and invalidation are understood. Never cache private tenant responses across users or tenants.

## 17. Engineering rules

1. Understand workflow and permissions before implementation.
2. Never weaken RLS to make a feature work.
3. Never expose service-role secrets client-side.
4. Schema changes require migrations.
5. Do not silently modify unrelated functionality.
6. Mock data is not proof of completion.
7. Do not claim a security control is implemented until tested.
8. Review dependency maintenance and licences.
9. Document deviations.
10. Prefer incremental, reviewable changes.
