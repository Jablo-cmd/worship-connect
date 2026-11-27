# Worship Connect — Delivery Roadmap

**Version:** 1.0 | **Status:** Proposed sequence; no delivery dates committed

## Delivery strategy

Build a secure operating foundation, then deliver complete workflows incrementally. A phase is complete only after acceptance criteria, security checks, tests and documentation are satisfied.

## Phase 0 — Repository and engineering foundation
**Scope:** Confirm stack and supported versions; application skeleton; lint, format and type checks; tests; environment conventions; local Supabase; migrations; CI; setup/deployment docs.

**Exit:** Clean documented local setup; CI checks; no secrets in Git; preview/production strategy documented.

## Phase 1 — Identity, tenancy and church administration
**Scope:** Authentication, profiles, tenants, owner membership, multi-tenant membership, workspace switching, invitations, RBAC, optional campus/ministry/department/team hierarchy, platform admin baseline and audit events.

**Exit:** Create/administer workspace; multiple memberships; tenant-specific roles; invitation lifecycle; cross-tenant tests; storage/realtime policy foundations.

**First major release gate.**

## Phase 2 — People, teams and member experience
**Scope:** Member directory, team membership, skills/instruments, vocal classifications, availability, team leaders, member dashboard and notification foundation.

**Exit:** Flexible teams; controlled profile editing; authorised availability; useful personalised member dashboard.

## Phase 3 — Music library and service planning
**Scope:** Song catalogue, metadata/tags, arrangements and sections, resources, services, programme items, service-specific song settings, assignments, responses, draft/published states and revision history.

**Exit:** Director can publish a service; members see assignments/resources; material changes are recorded and communicated; catalogue edits do not rewrite historical plans.

## Phase 4 — Rehearsals and scheduling
**Scope:** Rehearsal scheduling/agendas, participant invitations, attendance, song notes, practice tasks, calendars, conflict detection and reminders.

**Exit:** Rehearsal linked to service; attendance/follow-up recorded; leaders see preparation and scheduling gaps.

## Phase 5 — Communication and meetings
**Scope:** Team/department channels, service discussions, direct messages, attachments, replies, reactions, notifications, meeting agendas/minutes, decisions, action items and moderation.

**Exit:** Tenant/channel-secure communication; realtime isolation tests; meetings produce trackable actions.

## Phase 6 — Technical production
**Scope:** Production plans, stage layouts, input lists, microphones/DI, monitor requirements, patch notes, lighting/media cues, equipment checklists, soundcheck and templates.

**Exit:** Production teams prepare and execute service plan; updates visible to authorised participants.

## Phase 7 — Insights and advanced operations
**Scope:** Attendance, response, rehearsal, preparation, readiness reports; exports; member development; mentorship; scheduling suggestions; subscription entitlements and billing.

**Exit:** Reports respect permissions; metrics are contextual; entitlements enforced server-side.

## Phase 8 — Intelligent assistance and expansion
Potential scope: AI meeting summaries, rehearsal action extraction, setlist/transition suggestions, transposition assistance, substitute suggestions, native apps, advanced multi-campus workflows and integrations.

AI and automation recommendations remain reviewable by authorised leaders.

## Release management

Each release includes scope, acceptance criteria, migration review, security review, automated test results, manual workflow verification, known limitations, recovery/rollback plan and updated docs.

Use controlled rollout for incomplete or operationally risky features.

## Prioritisation

Prioritise work that removes recurring pain, connects the service lifecycle, improves member clarity, reduces leader administration, strengthens security/reliability or enables future modules without overengineering.

Do not build advanced AI, analytics or decorative dashboards before core workflows work reliably.
