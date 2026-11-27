# Worship Connect — Database Testing Strategy

**Version:** 0.1 (draft for review) | **Status:** Proposed — specification only. No test exists yet; no security control may be described as implemented until its tests pass (`TECHNICAL_ARCHITECTURE.md` §17.7).

Companion documents: [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) · [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) · [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) · [DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md) · `SECURITY_AND_PRIVACY.md` §14–15

---

## 1. Principles

1. **Test as the attacker, through the real boundary.** Security tests run as the `authenticated` role with a real JWT subject (SQL tests) or through `supabase-js` with real sessions against a local Supabase stack (integration tests). **A test that uses the service-role key proves nothing about RLS** and is only allowed for fixture setup.
2. **Every denial test has a paired positive test.** "B cannot read A's songs" is meaningful only if "A can read A's songs" passes in the same fixture; otherwise the test may pass because nothing works.
3. **Assert on data, not on error messages.** Under RLS a forbidden SELECT returns *zero rows*, a forbidden write returns an error or zero affected rows. Tests assert row counts, affected-row counts and the *absence* of state change — then re-read the row as an authorised user to prove it was not modified.
4. **Policies are mutation-tested.** For every policy family, CI runs a mutation step (§3.15) that deliberately weakens it and requires the suite to fail. A test suite that cannot detect a deleted policy is not a security test.
5. **Matrix-driven.** Role × permission × scope cases are generated from the same machine-readable source as the seed data (PERMISSIONS_MATRIX) so the documents, seeds, policies and tests cannot drift (§3.9).
6. **Release gate.** The isolation suites in §3.2–3.8 and §3.13–3.14 are mandatory for any release touching tenant data (SECURITY §14). They run on every pull request that changes `supabase/migrations/`, `supabase/seed/` or policies.
7. **Deterministic and hermetic.** Fresh database per run (`supabase db reset`), fixed UUIDs, time-dependent cases built from timestamps relative to `now()` in fixtures (no clock faking, no test hooks in production code), no network, no real data.

---

## 2. Fixtures

Two organisations with every membership state, so each requirement can be proven both ways. Fixed UUIDs live in one shared module used by SQL and TypeScript tests.

| Fixture | Org | State / roles | Purpose |
|---|---|---|---|
| `alice` | A | Owner (org scope) | Owner-only actions |
| `bob` | A | Admin (org scope) | Admin ≠ Owner |
| `carol` | A | Team Leader scoped to **Team A1** (Worship Band) | Scope boundary |
| `dan` | A | Member of Team A1 | Own-team access |
| `erin` | A | Member of Team A2 (Sound), plus Production Lead scoped to Team A2 | Other team; scoped technical lead |
| `felix` | A | **Suspended** (was Member of A1 with a role) | Suspended behaviour |
| `grace` | A | **Removed** | Removed behaviour |
| `heidi` | — | **Invited to A** (pending invitation; no membership) | Pre-acceptance |
| `ivan` | A **and** B | Member in A (Team A1); Worship Director in B | Multi-organisation |
| `judy` | B | Owner of B | Cross-tenant attacker/peer |
| `mallory` | — | Authenticated, no memberships | Outsider |
| `anon` | — | Unauthenticated (anon key) | Zero access |
| `support` | platform | `platform.admins` role `support`, **no grant** | Platform separation |
| `dept_leader` (`dora`) | A | Department Leader scoped to Department *Music* (contains Team A1) | Intermediate scope |

Seed per organisation: campus (A has two: A-North, A-South), ministry, department, two teams, locations, songs (incl. one with restricted `song_resources`), a draft service and a published service with assignments, a rehearsal, a task, a meeting with minutes, an announcement per scope, public and private channels, a DM between two members, files attached to each of: song resource, message, service, plus a private reason note on availability. **Every private record has a twin in organisation B** so isolation tests have something to leak.

---

## 3. Test suites

Test identifiers are stable (`ISO-…`) so reports and PR descriptions can cite them.

### 3.1 Catalogue and static checks (structure, no fixtures)

Run first; fail fast. Implemented as pgTAP over `pg_catalog` / `information_schema`.

| Id | Assertion |
|---|---|
| CAT-01 | Every table in `public` has `relrowsecurity = true` (and `relforcerowsecurity = true`). |
| CAT-02 | Every table in `public` has ≥1 policy **or** is in the explicit server-only list (RLS_SPEC P6) with *zero* grants to `authenticated`/`anon`. |
| CAT-03 | `anon` holds **no** privilege on any table, sequence or function in `public`, `private`, `platform`. |
| CAT-04 | `authenticated` has no privilege on `platform.*` or `private` *tables*; has `EXECUTE` only on the allow-listed helper/RPC functions. |
| CAT-05 | Every `SECURITY DEFINER` function has `proconfig` containing `search_path=""` (empty), is not owned by a role that clients can assume, and has `EXECUTE` revoked from `PUBLIC`. |
| CAT-06 | No function with a parameter named like `user_id`, `p_user`, `role` that is `SECURITY DEFINER` (identity-by-parameter ban). |
| CAT-07 | Every table with `organisation_id` also has `UNIQUE (organisation_id, id)` **or** is a documented leaf. |
| CAT-08 | Every foreign key from a tenant table to another tenant table is **composite including `organisation_id`** (query `pg_constraint`; exceptions allow-listed: FKs to global tables). |
| CAT-09 | FK graph has no cycles other than documented self-references. |
| CAT-10 | Every FK column set has a supporting index (leading columns). |
| CAT-11 | Every view in `public` has `security_invoker = true`; no materialised view is exposed to `authenticated`. |
| CAT-12 | Every policy expression referencing a permission key uses a key that exists in `permissions` (parse `pg_policies`; flag unknown literals). |
| CAT-13 | Every `UPDATE` policy has a `WITH CHECK`; every `INSERT` policy has a `WITH CHECK`. |
| CAT-14 | `organisation_id` is covered by the `forbid_org_change` trigger on every tenant table. |
| CAT-15 | Append-only tables (`audit_events`, `service_revisions`, `membership_status_events`, `policy_acceptances`, `*_revisions`) have the block-mutation trigger and no client UPDATE/DELETE privilege. |
| CAT-16 | No client role has any privilege (table or column) on `invitation_tokens`; no table granted to `authenticated` has a column named `*_hash`/`*_secret`/`*_token`. |
| CAT-17 | Tables/columns/policy names follow the conventions (lower snake case). |
| CAT-18 | Table inventory in `DATABASE_SCHEMA.md` §0.3 equals the set of tables in the catalogue (doc/DB drift). |
| CAT-20 | `private.is_valid_timezone` rejects `EST`, `UTC+3`, `Factory`, `Etc/GMT+5`, `posix/Europe/London`, empty/NULL; accepts `UTC`, `Europe/London`, `Africa/Johannesburg`, `Australia/Lord_Howe`. |
| CAT-21 | `audit_events` has partitions covering now()…now()+3 months and a `DEFAULT` partition that is empty (alert condition). |
| CAT-19 | Policy coverage equals the machine-readable RLS matrix (`rls_matrix.yaml`, generated from RLS_SPEC §6): for each table×operation, a policy exists iff the matrix says "direct"; none otherwise. |

### 3.2 Organisation isolation (requirement 1: *Organisation A cannot access Organisation B's data*)

Parametrised over **every tenant table** (generated from the catalogue + fixtures) and every operation. For each table *T* with a row `a` in A and `b` in B:

| Id | Actor | Action | Expected |
|---|---|---|---|
| ISO-01 | `judy` (B owner) | `select * from T where id = a.id` | 0 rows |
| ISO-02 | `judy` | `select * from T` | contains only B rows (count = B's count; none of A's ids) |
| ISO-03 | `judy` | `insert into T (organisation_id = A, …valid payload)` | rejected (RLS `WITH CHECK`) |
| ISO-04 | `judy` | `insert into T (organisation_id = B, parent_id = a_parent)` (forged cross-tenant FK) | rejected by **composite FK** even though `organisation_id=B` is permitted |
| ISO-05 | `judy` | `update T set … where id = a.id` | 0 rows affected; A's row unchanged (verified as `alice`) |
| ISO-06 | `judy` | `update T set organisation_id = A where id = b.id` | rejected (trigger + policy) |
| ISO-07 | `judy` | `delete from T where id = a.id` | 0 rows affected; row still exists |
| ISO-08 | `alice` (A owner) | mirror of ISO-01…07 against B's rows | same results (symmetry) |
| ISO-09 | `mallory` (no memberships) | select/insert/update/delete on every table | 0 rows / rejected |
| ISO-10 | `anon` | any operation on any table or RPC | permission denied |
| ISO-11 | `judy` | call each RPC passing A's ids as targets (`assign_role`, `set_membership_status`, `publish_service_revision`, …) | `forbidden` (generic error); no state change |
| ISO-12 | `judy` | PostgREST embedding / joins (`select *, parent(*)`) toward A rows | no A data via embeds |
| ISO-13 | `judy` | views `v_*` | only B-derived rows |
| ISO-14 | `judy` | `select count(*)` and aggregate functions on tenant tables | counts equal B-only (no count leakage) |
| ISO-15 | `judy` | supply guessed A UUIDs to every `*_id` filter and to Storage/Realtime | no data, indistinguishable from "not found" |

Positive twins: ISO-P1 `alice` reads/writes her permitted A rows on every table per her role; ISO-P2 `judy` likewise in B.

### 3.3 Membership state: suspended, removed, pending (requirements 3 and 5)

Executed per state with *the same* operation set as ISO-P1 for a user who previously had access.

| Id | Actor | Scenario | Expected |
|---|---|---|---|
| MEM-01 | `felix` (suspended) | read any A table that `dan` can read | 0 rows on all tables; `my_workspaces()` returns A with `status='suspended'` |
| MEM-02 | `felix` | any INSERT/UPDATE/DELETE in A, incl. own `member_unavailability`, own messages | rejected / 0 rows |
| MEM-03 | `felix` | call RPCs (`respond_to_assignment`, `mark_read`, `register_file`) for A | `forbidden` |
| MEM-04 | `felix` | Storage: read an A file he previously uploaded or could read | denied; signed-URL issuance refused |
| MEM-05 | `felix` | Realtime: join `org:A:conv:{c}` / `org:A:me:{felix}` (fresh join) | denied |
| MEM-06 | `felix` | Mid-session suspension: `dan` is active; `alice` suspends `dan`; `dan` repeats his previous query on the **same JWT without re-login** | 0 rows immediately (no token refresh needed) |
| MEM-07 | `felix` | Role revoked/expired: assignment `expires_at` passes (assignment created already-expired or expiring in 1 s) | permission-gated reads/writes stop at the exact instant |
| MEM-08 | `grace` (removed) | MEM-01…05 | denied; can be re-invited and re-activated (same membership id) after acceptance |
| MEM-09 | `felix` | Try to un-suspend himself, change own `status` via direct update, via `memberships_update_self` | rejected (status not client-updatable) |
| MEM-10 | `felix` | Accept a **new** invitation to A while suspended | rejected (suspension not bypassable) |
| MEM-11 | `dan` | Other organisation unaffected: `ivan` suspended in A keeps full access in B | B access intact |
| MEM-12 | organisation `suspended` by platform | every member of A | all denied instantly; B unaffected |
| MEM-13 | Last-owner guard | `alice` tries to remove/suspend/demote herself as the sole Owner | rejected; with a second Owner it succeeds |
| MEM-14 | Status transitions | illegal transitions (`removed→suspended`, `removed→active` directly) | rejected by trigger |
| MEM-15 | Notifications/attachments | notifications addressed to a suspended member are unreadable by them | 0 rows |

### 3.4 Scope, role escalation and administrative boundaries (requirements 2 and 4)

| Id | Actor | Scenario | Expected |
|---|---|---|---|
| SCP-01 | `dan` (member, A1) | read Team **A2**'s private data: team announcements scoped to A2, A2 `private` channel, A2 tasks, A2 members' availability, `member_private_notes`, `production_plans` owned by A2 | 0 rows each |
| SCP-02 | `dan` | read **own** A1 data and public A1 channel | succeeds (positive twin) |
| SCP-03 | `carol` (leader A1) | manage A1: create rehearsal, record attendance for A1 members, publish A1 announcement, assign A1 slots | succeeds |
| SCP-04 | `carol` | same actions on **A2** resources/members | rejected / 0 rows |
| SCP-05 | `carol` | org-owner actions: change organisation settings, create custom role, assign/revoke any role, suspend a member, read audit log, transfer ownership, invite to organisation scope | all rejected |
| SCP-06 | `carol` | try to give herself or `dan` `admin`/`owner`/`team_leader` for another team via `assign_role`, via direct INSERT/UPDATE on `membership_role_assignments` | rejected (no policy; RPC ceiling) |
| SCP-07 | `dora` (dept leader, Music) | assign `team_leader` for Team A1 (inside dept) | succeeds |
| SCP-08 | `dora` | assign `production_lead`, `admin`, or `team_leader` for Team A2 (outside dept) | rejected (ceiling / scope) |
| SCP-09 | `bob` (admin) | grant Owner | rejected (needs `org.ownership.manage`); `alice` succeeds (MFA step-up if configured) |
| SCP-10 | any | self-assignment: user calls `assign_role` targeting own membership | rejected |
| SCP-11 | `carol` | scoped grant never matches unscoped resource: edit an **org-wide** announcement or org-wide channel | rejected |
| SCP-12 | `erin` | Production Lead scoped to Team A2: manage plans owned by A2; not those owned by another team; cannot manage equipment of other teams | boundary respected |
| SCP-13 | custom role | Admin creates a custom role containing `org.ownership.manage` | rejected (trigger) |
| SCP-14 | permission scope validity | assign `music.manage` (org-only) via a team-scoped assignment | assignment accepted but permission **inert** (`has_perm` false) |
| SCP-15 | campus scope | campus-scoped Admin at A-North cannot read/modify A-South services, rehearsals, equipment | denied; can on A-North |
| SCP-16 | direct member updates | `dan` updates `memberships` of someone else; updates own `status`; own `organisation_id` | rejected |
| SCP-17 | Owner cannot read private data | `alice` reads `member_unavailability_notes` of `dan`, `dan`↔`erin` DM, private channel she is not in | 0 rows |
| SCP-18 | Admin audit | `bob` reads `audit_events` (allowed); `carol` (denied); neither can UPDATE/DELETE | as stated |
| SCP-19 | Draft visibility | member cannot read **draft** service; slot-assigner for a team can; participants see published only | as stated |
| SCP-21 | role-definition escalation | A member holding `roles.manage` through a custom role edits that same role to add `members.suspend`; adds a permission they lack to any custom role; creates a role containing `org.ownership.manage` | all rejected |
| SCP-20 | Role-assignment table | `dan` selects `membership_role_assignments`: sees own + directory-visible leader assignments, not others' admin assignments | as stated |

### 3.5 Invitations (requirement 5)

| Id | Scenario | Expected |
|---|---|---|
| INV-01 | `heidi` (pending invite, not accepted) selects every tenant table, `organisations`, `memberships`, `invitations`, Storage, Realtime for A | 0 rows / denied everywhere |
| INV-02 | `heidi` calls `get_invitation_preview(token)` | returns only org name, inviter name, expiry |
| INV-03 | `heidi` selects `invitations` directly | 0 rows (no policy for invitees); `invitation_tokens` unreadable even for `alice` |
| INV-04 | Accept with correct token + verified e-mail | membership active; baseline `member` role; team pre-assignments; invitation `accepted`; audit event; **only now** does ISO-P1-style read access appear |
| INV-05 | Accept with wrong token / expired / revoked / already used | identical generic error; no state change; timing does not differ measurably (statistical test, loose bound) |
| INV-06 | Accept with a token issued for another e-mail | rejected |
| INV-07 | Accept with **unverified** e-mail | rejected |
| INV-08 | Accept the same token twice concurrently (two sessions) | exactly one membership; second fails (row lock) |
| INV-09 | `carol` creates invitation outside her `members.invite` scope; with role exceeding her ceiling; with teams outside scope | rejected |
| INV-10 | Revocation: revoke then accept | rejected; revoke by non-inviter without permission rejected |
| INV-11 | Expired invitations purged after retention; accepted invitation retains audit trail only | per policy |
| INV-12 | Invitation token never appears in tables, logs or audit rows (search DB dump & captured logs for the raw token) | not found |
| INV-13 | Resend throttle and per-user acceptance attempt rate limits (edge) | enforced |
| INV-14 | Invite for an e-mail that already has an active membership | idempotent / rejected per rule; no duplicate user |

### 3.6 `SECURITY DEFINER` functions and RPCs

| Id | Test |
|---|---|
| DEF-01 | Each RPC called by `anon` → denied; called by `mallory` with valid-looking ids → `forbidden`. |
| DEF-02 | Each helper invoked with a hostile `search_path` set in the session (`set search_path = pg_temp, public`) still resolves identically (shadow tables/functions in `pg_temp` and `public` do not alter results). |
| DEF-03 | Helpers return only booleans/ids; cannot be used to enumerate other tenants (calling `has_perm(B, …)` as A member → false). |
| DEF-04 | Each RPC derives organisation from the target row: pass an id from B plus a "claimed" org id from A → rejected. |
| DEF-05 | Fuzz RPC parameters (nulls, empty arrays, mismatched types, oversized strings, SQL metacharacters, unicode homoglyph e-mails) → no privilege change, generic errors. |
| DEF-06 | Error uniformity: RPC failures for "not found" and "forbidden" are indistinguishable (same SQLSTATE class/message). |
| DEF-07 | Every RPC that changes authority writes an audit event; failure paths do not partially commit (atomicity) — fault injection between steps of `create_organisation`, `accept_invitation`, `publish_service_revision`. |
| DEF-08 | `create_organisation` creates organisation, settings, owner membership, owner assignment, starter data atomically; forced failure leaves **zero** orphan rows. |

### 3.7 Integrity, cascades and constraints

| Id | Test |
|---|---|
| INT-01 | Cross-tenant parent reference attempted through every composite FK → violation. |
| INT-02 | Cascades: deleting a parent as a user who could not delete a child directly (e.g. draft service with a published-service-only child policy) is not possible: parent DELETE policy at least as strict as children (generated: for each cascading FK compare policies). |
| INT-03 | `ON DELETE RESTRICT` history parents (`songs`, `positions`, `memberships`) cannot be deleted while referenced. |
| INT-04 | CHECK constraints reject: `ends_at <= starts_at`; invalid keys/time signatures/BPM; RS-column mismatch; `num_nonnulls` violations in `file_attachments`, `attendance_records`, `tasks`; invalid IANA zone; non-HTTPS external URLs; scope ancestor inconsistency. |
| INT-05 | UNIQUE constraints: one membership per (org, user); one pending invitation per (org, email); one slot per (service, position, slot_number); one attendance per (event, member); idempotent `client_message_id`. |
| INT-06 | Deferrable position uniqueness allows reorder within a transaction. |
| INT-07 | Exclusion constraint prevents double-booking a single-quantity equipment item; multi-quantity trigger enforces capacity. |
| INT-08 | State machines: illegal service/rehearsal/meeting/membership transitions rejected; `completed` services immutable except notes. |
| INT-09 | Optimistic concurrency: stale `row_version` update fails; concurrent publish yields one revision. |
| INT-10 | `service_revisions`/audit append-only: UPDATE/DELETE/TRUNCATE rejected for every client role and for definer-less contexts. |
| INT-11 | Songs: catalogue edits after publication do not change `service_songs` snapshot fields or previous revision snapshots. |
| INT-12 | Rights gating: writing lyrics/chords/audio resource without `allow_*_storage` rejected; with flag accepted. |
| INT-13 | Scope ancestors derived by trigger: a client-supplied wrong `campus_id` for a team-scoped row is overwritten/rejected. |
| INT-14 | Timezone/recurrence golden files across DST (S-7) incl. gaps and overlaps; pins PostgreSQL behaviour: gap time shifts forward (London 2027-03-28 01:30 → 02:30 BST), overlap resolves to the later standard-time instance; Lord Howe 30-minute shift; zones without DST stay stable. |
| INT-15 | Erasure: `erase_my_account()` removes PII, keeps shared records attached to an anonymised membership; unavailability notes, contacts and private notes removed. |

### 3.8 Users in multiple organisations (requirement 6)

| Id | Scenario | Expected |
|---|---|---|
| MUL-01 | `ivan` (member in A, Worship Director in B) queries `songs` **without** an organisation filter | returns A songs (via `music.view`) and B songs, **no others**; each row's permissions evaluated for its own organisation |
| MUL-02 | Authority does not bleed: `ivan` tries `songs` INSERT in A (needs `music.manage`; he is only a Member in A) → rejected; same insert in B → succeeds |
| MUL-03 | `ivan` assigns a role in A using his B authority (pass B's role/scope ids) | rejected |
| MUL-04 | Referencing across: create a B service referencing an A song / A position / A member | rejected by composite FKs |
| MUL-05 | Workspace switch: server action `switch(B)` with a membership he lacks (C) | denied; with B → context changes; **no DB state** records "active org" |
| MUL-06 | Switch with stale client state: client sends `organisation_id = A` after switching UI to B; row-level result is still correct for A (RLS ignores UI state) and caches are keyed by org (E2E: no cross-org data after switching) |
| MUL-07 | `ivan` suspended in A, active in B | A denied, B intact (MEM-11) |
| MUL-08 | One account/two e-mail identities cannot merge organisations; a second sign-up with the same e-mail cannot create a duplicate profile | per auth rules |
| MUL-09 | Cross-organisation profile isolation: A cannot read `profiles` rows (even of its own members); sees only `memberships.display_name`; `ivan`'s different names per church stay separate | as stated |
| MUL-10 | Direct conversations never span organisations: attempt `create_conversation` with a participant from B | rejected |
| MUL-11 | Notifications for B are not visible when querying with A membership; `notifications.recipient_membership_id` is per membership | as stated |

### 3.9 Permission-matrix ↔ policy ↔ document consistency (requirement: "matrix agrees with RLS")

| Id | Test |
|---|---|
| MTX-01 | Parse `PERMISSIONS_MATRIX.md` §2 and §4 into JSON in CI; compare with seed data in `permissions`, `roles`, `role_permissions` (keys, allowed scopes, sensitive flags, role→permission pairs, **per-role counts** in the matrix's count row). Mismatch fails the build. |
| MTX-02 | Every permission key appearing in RLS_SPEC (regex over §4–§7 SQL) exists in `permissions`; every permission is referenced by at least one policy or RPC (no dead permissions) — report, allow-list documented exceptions. |
| MTX-03 | **Generated behavioural matrix:** for each (role, permission, scope-position) combination the generator creates a user holding exactly that role at that scope and, for each table/operation whose RLS_SPEC row names the permission, asserts allow-inside-scope and deny-outside-scope using the fixtures. |
| MTX-04 | **Negative matrix:** a user with *only* `member` must be denied every operation in the matrix that names any other permission. |
| MTX-05 | No role other than Owner holds `org.ownership.manage`; only Owner/Admin hold `roles.manage`, `members.suspend`, `audit.view`, `files.manage` (assert from the catalogue). |
| MTX-06 | No role/permission grants read of `direct`/`group`/`private` conversations (assert no policy branch references `channels.manage`/`messages.moderate` for those kinds — via behavioural tests PRV-01…). |
| MTX-07 | `allowed_scopes` honoured: for each permission and each disallowed scope, effective permission is false. |

### 3.10 Service-role key, secrets and privileged server paths

| Id | Test |
|---|---|
| SEC-01 | Static scan (CI): no service-role key literal/regex in repo, `.env*` committed files, bundles; `NEXT_PUBLIC_*` contains no secret names. Secret-scanning (e.g. gitleaks/GitHub secret scanning) enabled. |
| SEC-02 | Built client bundle and source maps scanned for the service-role key and the `postgres` connection string → not present. |
| SEC-03 | Admin-client factory imported only from allow-listed server directories with `import 'server-only'` (ESLint rule / dependency-cruiser). |
| SEC-04 | Every allow-listed privileged endpoint (webhooks, workers, console) rejects unauthenticated and unauthorised callers **before** any elevated query (integration test with a spy on the admin client). |
| SEC-05 | Privileged endpoints ignore a client-supplied `organisation_id`: send A's id while authenticated as B → B's context used / request rejected. |
| SEC-06 | `service_role` JWT used from the "browser" test harness would work (documented), proving why SEC-01…03 matter; test asserts the app never emits such a JWT. |
| SEC-07 | Logs: capture application and Postgres logs during the suites; assert absence of tokens, invitation tokens, JWTs, note bodies, message bodies. |
| SEC-08 | Platform console: `support` without grant cannot read content (`platform` functions return metadata only); with a valid grant can read allowed content but **not** DMs/private channels; expired/revoked grant denied; each access logged and visible to Owners. |
| SEC-09 | Rate-limit tests on invitation acceptance, sign-in, recovery and file registration (edge/application layer). |

### 3.11 Performance and scalability regression (RLS cost)

| Id | Test |
|---|---|
| PRF-01 | Seed a synthetic large dataset (S-4 sizes). `EXPLAIN (ANALYZE, BUFFERS)` key list queries *as `authenticated`* (songs list, my schedule, service roster, inbox, notifications, attendance report) and record p95; budgets stored in the repo; CI fails on regression >X %. |
| PRF-02 | Plans show index scans on the RLS helper tables (`memberships (user_id, organisation_id)`, `membership_role_assignments (membership_id)`, `role_permissions`); no sequential scans on them. |
| PRF-03 | Policy predicates use `(select …)` wrappers (static check on `pg_policies.qual` text for `auth.uid()` without `select`). |
| PRF-04 | `pg_stat_statements` smoke after suites: no unexpectedly hot helper. |
| PRF-05 | Unused/missing index report (advisors) reviewed per release. |

### 3.12 Privacy: messages, notes, availability (requirement 7)

| Id | Scenario | Expected |
|---|---|---|
| PRV-01 | DM between `dan` and `erin`: `alice` (Owner), `bob` (Admin), `carol`, a moderator with `messages.moderate`, `platform support` with a content grant → `select` on `conversations`, `conversation_participants`, `messages`, `message_attachments`, `message_reactions` | 0 rows each |
| PRV-02 | `mallory`, `judy`, `heidi`, `felix` same | 0 rows |
| PRV-03 | Group conversation and **private channel**: non-participants (including channel managers) cannot read messages; `channels.manage` holder can archive/rename but not read, and **cannot add themselves** (or be added by another manager without being a participant-owner) | as stated |
| PRV-04 | Participant who **left** (`left_at` set) loses access to new *and* historical messages | 0 rows |
| PRV-05 | Reporting: `dan` reports a DM message; moderator sees `message_reports.body_snapshot` only (not the thread); moderator cannot fetch neighbouring messages | as stated |
| PRV-06 | Sender spoofing: insert with another `sender_membership_id`; insert into a conversation not accessible; insert with another organisation's conversation id | rejected |
| PRV-07 | Edit/delete: only own message editable (within window); others' edits rejected; delete = tombstone clears body & attachments; moderators cannot tombstone DMs | as stated |
| PRV-08 | Read markers: user cannot set another member's `last_read_*`; cannot read other participants' markers beyond policy | as stated |
| PRV-09 | Mentions: mentioning a non-participant creates no notification and leaks no content | as stated |
| PRV-10 | Notifications contain no message body; `notifications` of other users invisible | as stated |
| PRV-11 | Message search (FTS) as non-participant returns nothing from private conversations; ranking functions do not leak counts | as stated |
| PRV-12 | Availability reasons: leaders (`availability.view`, `services.assign`) cannot read `member_unavailability_notes`; owner reads own | as stated |
| PRV-13 | `member_private_notes`: subject cannot read; author and in-scope `members.notes.manage` can; out-of-scope leader cannot | as stated |
| PRV-14 | Emergency contacts visible only to subject and `members.notes.manage` over subject | as stated |
| PRV-15 | Contact details (`membership_contacts`) visible only to subject and `members.view_contact` over subject; ordinary members see none | as stated |
| PRV-16 | Decline reasons (`service_assignment_private`) invisible to roster viewers; visible to the member and slot assigners | as stated |
| PRV-17 | Attendance `note` and reports: member sees own; leaders see only in-scope members | as stated |
| PRV-18 | Metrics do not count `excused` as absent; reports expose no ranking view | as stated |

### 3.13 Files and Storage (requirement 8)

Run against the real Storage API of the local stack using real sessions.

| Id | Scenario | Expected |
|---|---|---|
| FIL-01 | `judy` requests/reads A's object by exact path and by guessed path/UUID; signed-URL request for A's file | denied (indistinguishable from not-found) |
| FIL-02 | `dan` reads a file attached to a message in a conversation he is **not** in; to a private channel; to a DM between others | denied |
| FIL-03 | `dan` reads a file attached to a message in a channel he can access | allowed (positive twin) |
| FIL-04 | Song resource with `access_scope='leaders'`: `dan` denied, `alice` allowed; `'assigned_members'`: assigned `dan` allowed, unassigned `erin` denied | as stated |
| FIL-05 | Suspended `felix`, removed `grace`, pending `heidi` | denied for every file incl. their own earlier uploads |
| FIL-06 | Upload without prior `register_file` (arbitrary path); to path with another org's prefix; with mismatched `file_id`; with another user's pending row; overwrite existing object (`upsert`) | rejected |
| FIL-07 | Upload by a **removed** member to a previously registered pending path | rejected (membership checked at upload time) |
| FIL-08 | File not yet `available` (pending/uploaded/quarantined/rejected/infected) | unreadable by everyone except uploader (pending) and server |
| FIL-09 | Oversize, wrong MIME, disallowed extension, polyglot (image with script) uploads | rejected at bucket/RPC/finaliser |
| FIL-10 | Client attempts to set `files.status='available'` or `scan_status='clean'` directly | rejected (no write grant) |
| FIL-11 | Listing: `storage.list` on prefixes of other organisations or the bucket root | empty/denied |
| FIL-12 | Signed URLs expire (≤60 s, tested with clock/short TTL) and are not reusable after membership removal beyond TTL; caching headers `private, no-store` | as stated |
| FIL-13 | Takedown: set `quarantined` → immediate read denial incl. for owner | as stated |
| FIL-14 | Delete: client cannot delete objects; `delete_file` soft-deletes; purge job removes object and row; attachments referencing deleted file become unreadable | as stated |
| FIL-15 | Avatar bucket: user can write only `{own uid}/…`; other users cannot read it directly; other members see only the org-owned copy | as stated |
| FIL-16 | Quotas: exceed per-member/org quota → `register_file` refuses | as stated |
| FIL-17 | Export files readable only by requester; expire after 7 days | as stated |

### 3.14 Realtime isolation

Two or more real clients subscribe via `supabase-js` to a local stack.

| Id | Scenario | Expected |
|---|---|---|
| RT-01 | `judy` subscribes to `org:A:conv:{c}`, `org:A:service:{s}`, `org:A:me:{alice}`, `org:A:presence` | join denied; no events received when A users act |
| RT-02 | `dan` subscribes to a DM topic of others, or to a private channel he is not in | denied |
| RT-03 | Positive: participants receive `message.created` with **id-only** payload; payload contains no body, name or file path | verified by inspecting the raw payload |
| RT-04 | Client attempts to `send`/broadcast onto `conv`/`service`/`me` topics | rejected; only presence on `org:X:presence` allowed |
| RT-05 | Topic parsing: malformed topics, wrong org/id combination (`org:A:conv:{conv of B}`), SQL-ish strings | denied; no exception leakage |
| RT-06 | Revocation: `dan` is subscribed; `alice` suspends him; (a) `membership.revoked` arrives on his personal topic, (b) he reconnects/refreshes token → join denied, (c) any event he still receives carries only ids and a follow-up fetch returns 0 rows | as stated |
| RT-07 | Postgres Changes are **not** enabled for tenant-content tables (publication membership assertion) | enforced |
| RT-08 | Reconnect/missed events: client resumes from last message id; duplicates handled idempotently | as stated |
| RT-09 | Presence reveals only directory-visible data | as stated |

### 3.15 Mutation testing of policies (meta-test)

A CI job copies the migrated database, applies a catalogue of **mutations**, and requires at least one test to fail for each:

* drop a policy; replace `has_perm(...)` with `true`; remove `status='active'` from `is_member`; remove the `organisation_id` from a join; drop `WITH CHECK`; widen `can_access_conversation` with a manager branch; remove `FORCE`/grant `anon`; drop a composite FK; make a definer function use `search_path = public`.
* Surviving mutants fail the build; the mutation list grows whenever a policy family is added.

---

## 4. Requirement → proof map (the eight required guarantees)

| # | Guarantee | Proven by |
|---|---|---|
| 1 | Organisation A cannot access Organisation B's data | ISO-01…ISO-15 (+ISO-P1/P2), CAT-07/08, INT-01, DEF-04, PRF none |
| 2 | A member cannot access another team's private information without permission | SCP-01, SCP-02, SCP-11, SCP-12, SCP-20, MTX-03/04, PRV-12…PRV-17 |
| 3 | A suspended member cannot continue using organisation resources | MEM-01…MEM-15, FIL-05, RT-06 |
| 4 | A team leader cannot perform organisation-owner actions | SCP-05, SCP-06, SCP-08, SCP-09, SCP-10, SCP-13, MTX-05 |
| 5 | An invited user cannot access an organisation before accepting | INV-01…INV-03, INV-05…INV-08, MEM-10, FIL-05 |
| 6 | A multi-organisation user can switch safely | MUL-01…MUL-11, MEM-11, E2E switching test (§5) |
| 7 | Private messages remain private | PRV-01…PRV-11, SCP-17, RT-02, RT-03, FIL-02, MTX-06 |
| 8 | File access respects organisation and membership permissions | FIL-01…FIL-17, CAT-04, ISO-15 |

---

## 5. Tools and frameworks

| Purpose | Tool | Notes |
|---|---|---|
| Local stack | **Supabase CLI** (`supabase start`, `db reset`) | Real Auth/PostgREST/Storage/Realtime, matches production behaviour |
| SQL-level tests | **pgTAP** via `supabase test db` | Catalogue tests, constraint tests, RLS tests under `set local role authenticated` with `request.jwt.claims` set |
| Test helpers | **`supabase_test_helpers`** (basejump) — `tests.create_supabase_user`, `tests.authenticate_as`, `tests.clear_authentication`, `tests.rls_enabled` | Validate availability/version in spike S-9; otherwise a small in-repo equivalent |
| Integration tests | **Vitest + `@supabase/supabase-js`** with real password/OTP sessions from the fixture users | Exercises PostgREST, Storage and Realtime exactly as the browser would |
| E2E | **Playwright** (pre-installed Chromium) | Workspace switching, invitation flow, suspended UX, no stale data after switch; run with `--trace off` by default |
| Static/security lint | `supabase db lint`, Supabase **Advisors** (security + performance) / splinter, `sqlfluff` (style), `squawk` (migration safety: locks, rewrites) | CI fails on new warnings |
| Secret scanning | gitleaks + GitHub secret scanning | SEC-01 |
| Dependency/code rules | ESLint (`no-restricted-imports` for admin client), dependency-cruiser | SEC-03 |
| Performance | `EXPLAIN ANALYZE` harness, `pgbench`/k6 against local stack, `pg_stat_statements` | PRF-* |
| Mutation | Small script applying SQL mutations to a template DB and re-running pgTAP | §3.15 |
| Time | Expiry/timing cases are made deterministic by writing `expires_at`/`starts_at` values relative to `now()` in fixtures (e.g. `now() - interval '1 second'`) rather than by faking the clock; production code contains no test hooks | Deterministic expiry tests |

### 5.1 Example: pgTAP RLS test (SQL level)

```sql
begin;
select plan(5);

-- fixtures are created with fixed UUIDs by the loader (superuser only at setup time);
-- :'org_a' etc. stand for those constants in this illustration
select tests.create_supabase_user('dan');    -- member of A, Team A1
select tests.create_supabase_user('judy');   -- owner of B
-- ... memberships, roles, songs inserted by fixture loader ...

-- positive twin
select tests.authenticate_as('dan');
select is((select count(*) from public.songs where organisation_id = :'org_a'), 12::bigint,
          'ISO-P1: member of A reads A songs');

-- cross-tenant read
select tests.authenticate_as('judy');
select is((select count(*) from public.songs where organisation_id = :'org_a'), 0::bigint,
          'ISO-01: B owner reads zero A songs');

-- cross-tenant insert (forged organisation_id)
select throws_ok($$ insert into public.songs (organisation_id, title) values (:'org_a', 'x') $$,
          '42501', null, 'ISO-03: B owner cannot insert into A');

-- cross-tenant update affects nothing
select is((with u as (update public.songs set title='pwned' where id = :'song_a1' returning 1)
           select count(*) from u), 0::bigint, 'ISO-05: update touches 0 rows');
select tests.clear_authentication();

-- ...and A's data is untouched
select tests.authenticate_as('alice');
select is((select title from public.songs where id = :'song_a1'), 'Way Maker', 'ISO-05: A row unchanged');

select * from finish();
rollback;
```

### 5.2 Example: integration test through the real API (TypeScript)

```ts
// tests/integration/iso-cross-tenant.test.ts
import { clientFor } from '../helpers/clients'      // creates a supabase-js client with a real session
import { fixtures as f } from '../helpers/fixtures' // fixed UUIDs

describe('ISO: organisation B cannot reach organisation A', () => {
  it('judy reads zero A songs, alice reads A songs', async () => {
    const judy = await clientFor('judy'); const alice = await clientFor('alice')
    const bRead = await judy.from('songs').select('id').eq('organisation_id', f.orgA)
    const aRead = await alice.from('songs').select('id').eq('organisation_id', f.orgA)
    expect(bRead.data).toEqual([])            // no rows – and no error disclosing existence
    expect(aRead.data!.length).toBeGreaterThan(0)
  })

  it('cannot move a row across tenants', async () => {
    const judy = await clientFor('judy')
    const r = await judy.from('songs').update({ organisation_id: f.orgA }).eq('id', f.songB1).select()
    expect(r.data ?? []).toHaveLength(0)
    const check = await (await clientFor('judy')).from('songs').select('organisation_id').eq('id', f.songB1).single()
    expect(check.data!.organisation_id).toBe(f.orgB)
  })

  it('suspension is effective on the same session, no re-login', async () => {
    const dan = await clientFor('dan')
    expect((await dan.from('songs').select('id')).data!.length).toBeGreaterThan(0)
    await (await clientFor('alice')).rpc('set_membership_status', { p_membership: f.danMembership, p_to: 'suspended', p_reason: 'test' })
    expect((await dan.from('songs').select('id')).data).toEqual([])       // same JWT, zero rows
  })
})
```

### 5.3 Example: Storage and Realtime

```ts
it('judy cannot read or sign an A file', async () => {
  const judy = await clientFor('judy')
  const r1 = await judy.storage.from('org-files').createSignedUrl(`${f.orgA}/${f.fileA1}/chart.pdf`, 60)
  expect(r1.data).toBeNull()
  const r2 = await judy.storage.from('org-files').download(`${f.orgA}/${f.fileA1}/chart.pdf`)
  expect(r2.data).toBeNull()
})

it('judy cannot join a private A conversation topic', async () => {
  const judy = await clientFor('judy')
  const ch = judy.channel(`org:${f.orgA}:conv:${f.dmDanErin}`, { config: { private: true } })
  const status = await new Promise(res => ch.subscribe(s => ['SUBSCRIBED','CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(s) && res(s)))
  expect(status).not.toBe('SUBSCRIBED')
})
```

---

## 6. Continuous integration

| Stage | Trigger | Content | Blocking |
|---|---|---|---|
| 1. Static | every PR | `sqlfluff`, `squawk`, secret scan, ESLint security rules, doc/DB drift (CAT-18), matrix parse (MTX-01) | Yes |
| 2. Database | PRs touching migrations/policies/seeds/docs | `supabase start` → `db reset` → `db lint` → `supabase test db` (CAT, ISO, MEM, SCP, INV, DEF, INT, MTX, PRV SQL-level) → advisors | Yes (**release gate**) |
| 3. API integration | same | Vitest integration (ISO via API, MUL, FIL, RT, SEC) against the local stack | Yes (**release gate**) |
| 4. Mutation | nightly + on policy changes | §3.15 | Yes for policy PRs |
| 5. Performance | nightly | PRF-* on synthetic dataset | Warn → block on >X % regression |
| 6. E2E | before release/merge to main | Playwright workspace switching, invitation, suspension UX | Yes for release |
| 7. Pre-production | on release | repeat stage 2–3 against a production-like preview project with synthetic data; verify no secrets; migration dry-run | Yes |

**Release gate (SECURITY §14)** = stages 2, 3 and 6 green, advisors clean, no surviving mutants, and an up-to-date `rls_matrix.yaml`.

**Flake policy:** a failing security test is never "re-run until green"; it is investigated. Quarantining or skipping a security test requires an entry in `DECISIONS.md` and is forbidden for the §4 proof-map tests.

## 7. Reporting and evidence

* Each run publishes a test report keyed by test id, listing the eight guarantees in §4 with pass/fail and the commit SHA, retained with the release (evidence for "do not claim a control is implemented until tested").
* Coverage metric that matters: **policy coverage** — the percentage of (table × operation × role-class) cells in `rls_matrix.yaml` exercised by at least one positive and one negative test. Target 100 % before onboarding real churches.
* New table or policy without matrix and tests fails CAT-19.

## 8. Manual and periodic security activities

| Activity | When |
|---|---|
| Security review of every Phase-1 migration and every `SECURITY DEFINER` function | Before Phase-1 exit and on change |
| Independent penetration test focused on tenant isolation, invitations, storage, realtime | Before first real church; annually |
| Access review of `platform.admins` and `support_access_grants` | Quarterly |
| Backup restore drill including re-application of erasure requests | Before launch; semi-annually |
| Key rotation drill (service-role key, JWT secret) | Annually and after any suspected exposure |
| Advisor/lint review and unused-index review | Every release |
