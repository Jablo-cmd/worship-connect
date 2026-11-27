# Worship Connect — Product Requirements Document

**Version:** 1.0 | **Status:** Initial product baseline | **Product:** Multi-tenant SaaS

## 1. Vision

Worship Connect is a unified operating platform for church worship ministries. It connects people management, music preparation, service planning, rehearsals, communication, meetings and technical production.

It is not merely a messaging app, calendar or song database. It supports the full operational lifecycle: plan, assign, prepare, rehearse, execute and review.

**Product promise:** One place to organise people, prepare music, coordinate services and manage worship ministry operations.

## 2. Problems to solve

1. Scheduling happens across fragmented messages and spreadsheets.
2. Leaders do not know availability early enough.
3. Members receive incomplete or late assignment information.
4. Keys, arrangements, lyrics, charts and recordings are scattered.
5. Rehearsals lack structure, attendance records and follow-up.
6. Decisions disappear in chat conversations.
7. Musicians, vocalists and production teams work from different service plans.
8. Sound and stage requirements arrive late.
9. Last-minute changes are not reliably communicated.
10. Leaders lack visibility into participation, preparation and outstanding tasks.
11. New members are onboarded inconsistently.
12. Multi-campus churches need shared coordination with scoped access.

## 3. Product principles

- **One source of truth:** Current approved service plans and schedules must be identifiable.
- **Member clarity:** Every member sees assignments, commitments and preparation requirements.
- **Operational visibility:** Leaders see outstanding confirmations, preparation gaps and technical readiness.
- **Connected workflows:** Services, songs, assignments, rehearsals, production and discussion are related.
- **Flexible organisation:** Small churches are not forced into enterprise structures.
- **Secure by default:** Tenant isolation and server-side permissions are foundational.
- **Respectful accountability:** Participation data supports improvement and pastoral care, not public shaming.
- **Mobile-first usability:** Common member actions work comfortably on phones.

## 4. Users

- Platform super administrators and support personnel.
- Church owners and church administrators.
- Senior and worship pastors.
- Worship directors and music directors.
- Department and team leaders.
- Musicians and instrumentalists.
- Lead and backing vocalists, choir and orchestra members.
- Sound, lighting, projection, media and livestream operators.
- General ministry members.

## 5. Tenant and organisation model

Each church is an independent tenant. Tenant-owned data includes members' church memberships, organisational structure, music, services, rehearsals, conversations, files, settings and reports.

A global user may belong to multiple churches. Membership, roles and permissions are evaluated independently in each church.

Support an optional hierarchy:

Church → Campus → Ministry → Department → Team → Members.

Do not require every level. Multiple departments must be able to collaborate on shared services while retaining appropriate permissions.

## 6. Functional requirements

Priority: **P0** = foundation/initial release; **P1** = core operational product; **P2** = advanced/later.

### 6.1 Platform administration — P0/P2
- Tenant directory and status.
- Platform-level operational overview.
- Subscription plans and entitlements (P2).
- Suspension and reactivation.
- Audited, purpose-limited support access.
- Platform health and configuration.

Platform staff must not casually browse private church conversations or member data.

### 6.2 Church registration and onboarding — P0
- Create church workspace and owner membership.
- Capture church name, contact details and timezone.
- Configure optional campuses, ministries, departments and teams.
- Invite leaders and members.
- Offer simple templates or a start-from-scratch path.
- Show onboarding progress and allow optional steps to be skipped.

Workspace creation must be transactional or recoverable; failed onboarding must not leave inaccessible orphan records.

### 6.3 Identity, membership and RBAC — P0
- Secure registration, sign-in and recovery.
- Global user profile.
- Multiple church memberships.
- Workspace switching.
- Invitations with expiry, acceptance and revocation.
- Membership suspension and removal.
- Configurable roles and permissions.
- Tenant-specific and optionally scoped role assignments.
- Audit important membership and permission changes.

A role in one church must never grant the same permissions in another.

### 6.4 People and teams — P0/P1
Member profiles may include display name, contact details, profile image, church status, campus/team membership, instruments, vocal classification, skills, experience and availability preferences. Sensitive notes must be restricted and optional.

Support multiple team memberships per person.

### 6.5 Music library — P1
A searchable tenant-owned song catalogue containing title, artist, alternate titles, default/preferred key, BPM, time signature, language, tags, lyrics where lawful, chord charts, lead sheets, reference links, permitted audio resources, arrangement notes, status and version history.

Songs may have multiple arrangements. Each arrangement contains ordered sections such as intro, verse, chorus, bridge, instrumental, vamp, tag and outro.

Service-specific song choices must not overwrite canonical library data. Copyright and licensing responsibilities must be explicit. Uploaded documents must not be represented as automatically transposable.

### 6.6 Service planning — P1
- Create services and special events with date, time, timezone, venue and campus.
- Ordered programme items: songs, prayer, scripture, announcements, transitions and other items.
- Select song arrangements, key, BPM, leader and service notes.
- Assign people and teams to roles.
- Track draft, published, completed and cancelled states.
- Record revisions to published plans.
- Notify affected members of material changes.
- Provide printable/shareable service plans.

### 6.7 Availability and scheduling — P1
- Member unavailable dates/date ranges.
- Service invitations and accepted, declined, tentative or pending responses.
- Conflict detection and unfilled role identification.
- Recurring services and rehearsals.
- Calendar views and timezone-aware display.
- Future substitute suggestions based on skills, membership and availability.

No response must not be treated as confirmation.

### 6.8 Rehearsals — P1
- Schedule rehearsals, optionally linked to services.
- Agenda, participants and song/section practice plan.
- Attendance and punctuality records.
- Song-specific notes and issues.
- Follow-up practice tasks.
- Recording links or uploads.
- Reminders and schedule-change notifications.

Avoid invasive or unreliable location-based attendance tracking.

### 6.9 Communication — P1
- Tenant announcements.
- Department/team channels.
- Service- and rehearsal-specific discussions.
- Direct and group messages.
- Text, replies, attachments, reactions, pinned messages and search.
- Voice notes subject to storage controls.
- Notification preferences.
- Moderation/reporting controls and message retention policy.

All channel and conversation access must be tenant- and membership-aware.

### 6.10 Meetings and tasks — P1
Schedule meetings, define attendees, prepare agendas, record minutes and decisions, assign action items and due dates, attach documents and track completion. Link meetings to teams, departments or services.

### 6.11 Technical production — P1/P2
- Stage plots and performer positions.
- Audio input lists, microphones and DI requirements.
- Monitor requirements.
- Keyboard/instrument patch notes.
- Lighting, projection and livestream cues.
- Equipment checklists.
- Soundcheck schedule and readiness.
- Reusable production templates.

### 6.12 Personal member workspace — P1
A role-aware dashboard showing upcoming services/rehearsals, assignments, arrival times, songs, charts, lyrics, recordings, technical instructions, preparation checklist, confirmations, announcements and relevant conversations.

A keyboardist, vocalist and sound engineer must receive appropriately different preparation views.

### 6.13 Reporting and development — P2
Attendance summaries, response rates, unfilled roles, rehearsal participation, preparation completion, team trends, action items, readiness reports, skills, mentorship and training.

Metrics must account for approved leave, illness, excused absence and schedule changes. Do not turn metrics into public rankings or shame mechanisms.

### 6.14 AI assistance — P2 / exploratory
Potential meeting summaries, rehearsal action extraction, setlist suggestions, arrangement help, transposition assistance and substitute suggestions. AI output must be labelled and reviewed before publication. External AI processing requires privacy and contractual review.

## 7. End-to-end weekly service lifecycle

1. Director creates a service.
2. Programme items and songs are selected.
3. Arrangements, keys, tempos and leaders are set.
4. Members and teams are assigned.
5. Invitations are sent and responses tracked.
6. Members prepare using their personalised workspace.
7. Rehearsals are conducted and follow-ups recorded.
8. Production requirements are prepared.
9. Final plan is published.
10. Changes are recorded and communicated.
11. Service is completed.
12. Attendance, issues and follow-up actions are captured.

## 8. Notifications

Events include invitations, reminders, responses, assignment changes, service publication/changes, rehearsal changes, announcements, mentions, direct messages, meetings, action assignments and technical readiness requests.

Start with in-app notifications. Add email and web push with preferences and delivery status.

## 9. Non-functional requirements

- Responsive and accessible on mobile and desktop.
- Paginated lists and message history.
- Reliable handling of retries and duplicate submissions.
- Clear loading, empty, success and error states.
- Store timestamps consistently and use IANA timezones.
- Support future localisation.
- Monitor database, storage, bandwidth and realtime costs.
- Avoid cross-tenant caching of private data.

## 10. Commercial readiness

Architecture should support future plans, tenant entitlements, usage limits and billing. Potential dimensions include active members, campuses, storage, recordings, reporting, production tools and AI usage.

Pricing, payment provider, free tier and limits are undecided. Do not hardcode commercial limits.

## 11. Initial out of scope

Unless separately approved: full congregation CRM, giving/tithing, accounting, payroll, pastoral case management, public livestream hosting, DAW functionality, automatic licensing clearance, and native mobile applications.

## 12. Initial foundation acceptance criteria

1. Secure registration and authentication.
2. Church workspace creation with owner membership.
3. Multiple church memberships per user.
4. Flexible departments and teams.
5. Invitation acceptance, expiry and revocation.
6. Tenant-scoped roles and permissions.
7. Direct API/database attempts cannot bypass tenant isolation.
8. Automated tenant isolation tests pass.
9. Important membership and permission changes are audited.
10. Responsive desktop/mobile experience.
11. Documented setup and deployment.
12. No secrets or sensitive test data in Git.

## 13. Open product questions

Final brand; self-service versus invitation-led registration; campus timing; default roles and permission matrix; profile creation flow; cross-campus services; music licensing; chat retention/moderation/export; billing provider and plans; notification providers.

## 14. Definition of done

A feature is complete only when its workflow and permissions are documented, tenant boundaries are tested, server-side enforcement exists, loading/empty/error/success states are implemented, responsive behaviour is verified, automated tests cover critical paths, schema changes use migrations and documentation is updated.
