# Worship Connect — Permissions Matrix

**Version:** 0.1 (draft for review) | **Status:** Proposed — specification only; nothing here is implemented or tested.

Companion documents: [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) · [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) · [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) · [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md)

This file is the **single source of truth for permission keys and the default role→permission mapping**. The RLS specification refers to these keys by name; the seed data for `permissions` and `role_permissions` must be generated from (or verified against) the tables in §4. Any permission key used in an RLS policy that is not listed here is a specification bug.

---

## 1. Model in one page

| Concept | Meaning |
|---|---|
| **Permission** | A stable text key such as `services.publish`. Defined by the platform in the `permissions` table; never created by tenants. |
| **Role** | A named bundle of permissions. **System roles** are global rows (`organisation_id IS NULL`), identical for every church, versioned with the code. **Custom roles** belong to one organisation and may only contain permissions from the catalogue. |
| **Role assignment** | `membership_role_assignments`: (membership, role, scope). The *only* way a person gains a permission. |
| **Scope** | Where an assignment applies: `organisation`, `campus`, `ministry`, `department` or `team`. A scoped assignment applies to a resource only if that resource carries the matching ancestor id. |
| **Position** | What a person *does* in a service (Lead Vocal, Keys, FOH Engineer, Slide Operator). Positions are **not** roles and grant no permissions. |
| **Skill** | What a person *can do* (instrument, vocal role, technical skill). Also grants nothing. |

**Why positions ≠ roles.** A keyboardist, a vocalist and a sound engineer all have the same administrative power (*none* beyond Member). Their difference is operational, so it lives in `positions`/`skills`. A sound **lead** receives the *Production Lead* role scoped to the sound team/department; that is a permission statement, not a job title.

### 1.1 Evaluation rules (normative)

1. **Active membership required.** Every permission check first requires an `active` membership in an `active` organisation. Suspended, removed, invited-but-unaccepted and non-members evaluate to *no permissions at all*.
2. **Additive only.** Permissions are the union of all of a member's non-expired assignments. There are no deny rules in v1 (see §6, overrides deferred).
3. **Scope matching.** An `organisation`-scope assignment matches every resource in the organisation. A `campus|ministry|department|team` assignment matches a resource only when `resource.<level>_id = assignment.<level>_id`. A scoped grant **never** matches a resource that has no value for that level (an org-wide announcement is not editable by a team leader).
4. **Permission scope validity.** Each permission lists `allowed_scopes`. An assignment at a scope not in that list contributes nothing for that permission (e.g. `music.manage` is organisation-only; granting it at team scope is inert).
5. **Privilege ceiling (anti-escalation).** A caller may assign a role only if (a) they hold `roles.assign` over the target scope, (b) they personally hold *every* permission in that role over that scope, (c) the target is not themselves, and (d) the role is not `owner` unless they hold `org.ownership.manage`.
6. **Role-definition ceiling.** Editing a custom role is also privileged: a caller may add a permission to a custom role only if they personally hold it at organisation scope, may never edit a role that is currently assigned to themselves, and may never put `org.ownership.manage` in a custom role. (Without this, anyone holding `roles.manage` through a custom role could grant themselves anything by editing their own role.)
7. **Last owner.** An organisation must always retain at least one active Owner; the database blocks any action that would remove the last one.
8. **Baseline (implicit) rights** need no permission and are listed in §5.
9. **Platform permissions are separate** (`platform.*` schema, §7); they never appear in church roles.

---

## 2. Permission catalogue

Scope key: **O** organisation · **C** campus · **M** ministry · **D** department · **T** team. "Sens." marks permissions that expose sensitive personal data or can change authority; they are always audited and are excluded from default custom-role templates.

### 2.1 Organisation and structure

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `org.settings.manage` | O | | Edit organisation profile, settings, preferences, defaults. |
| `org.ownership.manage` | O | ✔ | Assign/revoke the Owner role, transfer ownership, request closure/export of the organisation. |
| `structure.manage` | O C M D | | Create/edit/archive campuses, ministries, departments within scope. |
| `teams.manage` | O C M D T | | Create/edit/archive teams; manage team rosters and team positions within scope. |
| `locations.manage` | O C | | Manage venues and rooms. |

### 2.2 People

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `members.view_contact` | O C M D T | ✔ | See phone/contact e-mail of members in scope (names, avatars and team lists are visible to all active members). |
| `members.invite` | O C M D T | | Create/revoke invitations (with optional team pre-assignment inside scope). |
| `members.manage` | O C M D T | | Edit other members' organisation-level profile data, skills, positions on their behalf. |
| `members.suspend` | O C | ✔ | Suspend, reinstate, remove members; read non-active memberships and the status history. |
| `members.notes.manage` | O C M D T | ✔ | Read/write private leader notes and read restricted emergency contacts for members in scope. |
| `availability.view` | O C M D T | | See availability (dates only, never private reasons) of members in scope. |
| `onboarding.manage` | O C M D T | | Manage onboarding plans and verify onboarding steps. |
| `roles.manage` | O | ✔ | Create/edit/delete custom roles and their permission sets. |
| `roles.assign` | O C M D T | ✔ | Assign/revoke roles (subject to the privilege ceiling, §1.1 rule 5). |

### 2.3 Music library

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `music.view` | O | | Read songs, arrangements and resources whose `access_scope` permits the viewer. |
| `music.manage` | O | | Create/edit/archive songs, arrangements, sections, resources, tags, writers. |
| `music.rights.manage` | O | | Edit copyright/licence records and rights basis. |
| `music.notes.view` | O | | Read/write internal leader-only song notes. |
| `music.delete` | O | ✔ | Permanently delete songs/resources/files with no usage history. |

### 2.4 Services and planning

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `services.view` | O C | | Read **published/completed/cancelled** services in scope. |
| `services.view_drafts` | O C | | Read **draft** services in scope. |
| `services.create` | O C | | Create services and apply templates/series. |
| `services.edit` | O C | | Edit programme items, songs, notes, schedule fields. |
| `services.assign` | O C M D T | | Create/fill/clear assignment slots owned by the scope (slot's `team_id` ancestry). |
| `services.publish` | O C | | Publish, republish (new revision), reschedule, cancel. |
| `services.delete` | O C | ✔ | Delete **draft** services with no published history. |
| `services.templates.manage` | O C | | Manage service types, templates and recurring series. |

### 2.5 Rehearsals, attendance and tasks

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `rehearsals.view` | O C M D T | | Read all rehearsals in scope (participants always see their own). |
| `rehearsals.manage` | O C M D T | | Create/edit/cancel rehearsals, agendas, participants, notes. |
| `attendance.view` | O C M D T | ✔ | Read other members' attendance records in scope. |
| `attendance.record` | O C M D T | | Create/correct attendance records in scope. |
| `tasks.manage` | O C M D T | | Create/assign/close tasks for others in scope. |

### 2.6 Communication and meetings

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `announcements.publish` | O C M D T | | Publish announcements to the audience defined by the scope. |
| `channels.manage` | O C M D T | | Create/archive channels in scope; manage channel participants and moderators. **Does not grant read access to private channels or any direct message.** |
| `messages.moderate` | O C M D T | ✔ | Hide/remove messages in non-private channels in scope; review reports. **Never grants access to direct/group conversations or private channels.** |
| `meetings.manage` | O C M D T | | Create/edit meetings, agendas, participants, decisions, minutes. |
| `meetings.minutes.view_all` | O C M D T | | Read minutes of meetings in scope whose visibility is restricted. |

### 2.7 Technical production

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `production.view` | O C M D T | | Read production plans, stage plots, input lists and notes in scope (service participants may always read the plan for services they serve in, once it is published). |
| `production.manage` | O C M D T | | Edit production plans, stage plots, inputs, cues, checklists, requirements; allocate equipment. |
| `equipment.view` | O C M D T | | Read equipment inventory and allocations. |
| `equipment.manage` | O C M D T | | Create/edit/retire equipment and manage allocations. |

### 2.8 Reporting, audit and files

| Key | Allowed scopes | Sens. | Grants |
|---|---|---|---|
| `reports.view` | O C M D T | ✔ | Run reports (attendance, participation, task completion, usage) over members in scope. |
| `reports.export` | O C | ✔ | Export report data to a file (audited). |
| `audit.view` | O | ✔ | Read the organisation's audit log. |
| `files.manage` | O | | Delete or quarantine files uploaded by others (e.g. policy violations) through `delete_file`. **Grants no read or list access** to file content or filenames: it cannot open a DM attachment or an unattached file (verified on Supabase; an earlier draft let it, which leaked private attachments). |

**Total: 45 permissions.**

### 2.9 Mapping from the permission identifiers in `TECHNICAL_ARCHITECTURE.md` §6

| Existing identifier | Resolved to |
|---|---|
| `tenant.settings.manage` | `org.settings.manage` |
| `members.view` | Baseline (names/teams) + `members.view_contact` |
| `members.invite` | `members.invite` |
| `members.manage` | `members.manage` + `members.suspend` (split because suspension is sensitive) |
| `roles.manage` | `roles.manage` + `roles.assign` (split to enable the privilege ceiling) |
| `teams.manage` | `teams.manage` (+ `structure.manage` for campuses/ministries/departments) |
| `music.view` / `music.manage` | unchanged (+ `music.rights.manage`, `music.notes.view`, `music.delete`) |
| `services.view` / `services.create` / `services.publish` | unchanged (+ `view_drafts`, `edit`, `delete`, `templates.manage`) |
| `assignments.manage` | `services.assign` |
| `rehearsals.manage` | unchanged |
| `attendance.record` | unchanged (+ `attendance.view`) |
| `channels.manage` | unchanged |
| `messages.moderate` | unchanged (explicitly **cannot** read private conversations) |
| `meetings.manage` | unchanged |
| `production.manage` | unchanged (+ `production.view`, `equipment.*`) |
| `reports.view` | unchanged (+ `reports.export`, `audit.view`) |

---

## 3. System roles

| Role (`system_key`) | Intended holder | Assignable scopes | Notes |
|---|---|---|---|
| **Owner** (`owner`) | Church owner / lead administrator | O | At least one required. Only an Owner can grant Owner. |
| **Admin** (`admin`) | Church administrator | O, C | Everything except `org.ownership.manage`. A campus-scoped Admin administers one campus. |
| **Pastor** (`pastor`) | Senior/worship pastor, campus pastor | O, C | Oversight and approval; read-heavy; cannot edit the music library. |
| **Worship Director** (`worship_director`) | Worship/music director | O, C | Runs music library and service planning. |
| **Department Leader** (`department_leader`) | Head of a ministry or department (band, vocals, choir, audio, media) | M, D | Manages people and operations *inside the scope only*. |
| **Team Leader** (`team_leader`) | Leader of a team (e.g. Band A, Sound team) | T | Operates one team; no org-level or role-management power. |
| **Production Lead** (`production_lead`) | Technical director, head of sound/lighting/media | O, C, D, T | Owns production plans and equipment inside the scope. |
| **Member** (`member`) | Every ordinary member (musician, vocalist, operator, volunteer) | O | Auto-assigned on membership creation. |

The `member` role is assigned to every active membership by a trigger, so removing it is a deliberate, audited act.

---

## 4. Permission × role matrix

✔ = included in the role, effective over the scope at which the role is assigned (and only where the permission's *allowed scopes* permit). — = not included.

| Permission | Owner | Admin | Pastor | Worship Director | Dept Leader | Team Leader | Production Lead | Member |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `org.settings.manage` | ✔ | ✔ | — | — | — | — | — | — |
| `org.ownership.manage` | ✔ | — | — | — | — | — | — | — |
| `structure.manage` | ✔ | ✔ | — | — | — | — | — | — |
| `teams.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | — | — |
| `locations.manage` | ✔ | ✔ | — | — | — | — | — | — |
| `members.view_contact` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `members.invite` | ✔ | ✔ | — | ✔ | ✔ | — | — | — |
| `members.manage` | ✔ | ✔ | — | — | ✔ | — | — | — |
| `members.suspend` | ✔ | ✔ | — | — | — | — | — | — |
| `members.notes.manage` | ✔ | ✔ | — | — | ✔ | ✔ | — | — |
| `availability.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `onboarding.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | — | — |
| `roles.manage` | ✔ | ✔ | — | — | — | — | — | — |
| `roles.assign` | ✔ | ✔ | — | — | ✔ | — | — | — |
| `music.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| `music.manage` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `music.rights.manage` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `music.notes.view` | ✔ | ✔ | ✔ | ✔ | — | — | — | — |
| `music.delete` | ✔ | ✔ | — | — | — | — | — | — |
| `services.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| `services.view_drafts` | ✔ | ✔ | ✔ | ✔ | — | — | ✔ | — |
| `services.create` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `services.edit` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `services.assign` | ✔ | ✔ | — | ✔ | ✔ | ✔ | ✔ | — |
| `services.publish` | ✔ | ✔ | ✔ | ✔ | — | — | — | — |
| `services.delete` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `services.templates.manage` | ✔ | ✔ | — | ✔ | — | — | — | — |
| `rehearsals.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `rehearsals.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | — | — |
| `attendance.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `attendance.record` | ✔ | ✔ | — | ✔ | ✔ | ✔ | ✔ | — |
| `tasks.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | ✔ | — |
| `announcements.publish` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `channels.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | ✔ | — |
| `messages.moderate` | ✔ | ✔ | — | ✔ | ✔ | ✔ | — | — |
| `meetings.manage` | ✔ | ✔ | — | ✔ | ✔ | ✔ | ✔ | — |
| `meetings.minutes.view_all` | ✔ | ✔ | ✔ | ✔ | ✔ | — | — | — |
| `production.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — |
| `production.manage` | ✔ | ✔ | — | — | — | — | ✔ | — |
| `equipment.view` | ✔ | ✔ | ✔ | ✔ | — | — | ✔ | — |
| `equipment.manage` | ✔ | ✔ | — | — | — | — | ✔ | — |
| `reports.view` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | — | — |
| `reports.export` | ✔ | ✔ | — | — | — | — | — | — |
| `audit.view` | ✔ | ✔ | — | — | — | — | — | — |
| `files.manage` | ✔ | ✔ | — | — | — | — | — | — |
| **Permission count** | **45** | **44** | **14** | **30** | **23** | **19** | **17** | **2** |

> The counts row is a consistency check: the seed generator and the test suite must compute the same totals from the data. A mismatch means this document and the seed have drifted.

### 4.1 Scope notes that change the reading of the matrix

* **Department Leader / Team Leader** cells apply only inside the leader's assigned department/ministry/team. Where the permission's allowed scopes are O/C only (`services.view_drafts`, `services.publish`…), a scoped leader cannot hold it at all, which is why Department/Team Leaders are `—` on those rows.
* **Drafts for assigners.** A Department/Team Leader without `services.view_drafts` can still read a *draft* service in which a slot belonging to their team/department exists, because they hold `services.assign` over that slot. They see the service so they can fill the slot, nothing more.
* **Pastor** is intended for O or C scope; a Campus Pastor sees only that campus's services and rehearsals.
* **Production Lead** at D/T scope (e.g. the Sound team) cannot read org-wide `equipment.*` data outside that team's equipment.
* **Admin at campus scope** is bounded by the same scope matching; org-level resources (songs, roles, settings) require an org-scope assignment.

---

## 5. Baseline (implicit) rights — no permission required

These are granted by *being an active member* or *being a participant*, and are enforced by RLS, not by the permissions table.

| Right | Condition |
|---|---|
| See organisation name/settings that affect UI; see the **member directory** (display name, avatar, teams, public leadership roles) | Active member |
| Edit own organisation display name/avatar/home campus; own contact details; own skills, positions, vocal profile, song key preferences | Active member (own row) |
| Create/edit/delete own unavailability and its private note; own availability preferences | Active member (own row) |
| See own assignments, respond Accept/Decline/Tentative (via RPC), see the service plan *for services in which they hold an assignment* once published | Participant |
| See rehearsals/meetings they are invited to; respond to invitations | Participant |
| See tasks assigned to them and complete their own assignment | Assignee |
| See announcements whose audience includes them | Audience member |
| Open channels whose visibility includes them; read/post in conversations they participate in | Per conversation rules |
| Create direct/group conversations with other active members of the same organisation | Active member; organisation setting `allow_direct_messages` |
| Read/mark own notifications; manage own notification preferences | Active member |
| Upload files they are entitled to attach (subject to quota) | Active member |
| See own attendance records and own participation summary | Active member |
| Leave the organisation | Active member (not last Owner) |

---

## 6. Deferred: per-member permission overrides

`membership_permission_overrides` (grant/deny per member) is **not** in the v1 schema.

* **Why deferred:** every permission change must be explainable from role assignments; deny rules make effective permission non-monotonic and make RLS helper functions, caching and testing materially harder. Custom roles plus scoped assignments (and `expires_at` for temporary cover) express every use case identified so far.
* **Re-evaluate if:** more than a trivial number of churches ask for "same as role X but without Y" and custom roles prove unwieldy.
* **If added later:** grant-only overrides with mandatory `expires_at` and reason, audited; deny overrides only after a separate design review. Recorded as open decision **D-030**.

---

## 7. Platform-level access (separate from church roles)

| Platform role | Can do | Cannot do |
|---|---|---|
| `platform_support` | See organisation directory metadata (name, slug, status, plan, member *counts*); trigger password-recovery help; read tenant content **only** within an active, unexpired, organisation-granted `support_access_grant` | Browse messages, availability, notes, attendance without a grant; use the browser app with elevated rights |
| `platform_admin` | Suspend/reactivate organisations; manage plans/entitlements; manage `platform_admins`; process takedown requests | Read tenant content without a grant; assign church roles |
| `platform_superadmin` | Everything above plus break-glass access (dual approval, time-boxed, loudly audited, visible to the organisation's Owners) | Bypass audit |

Platform staff authenticate through a separate, MFA-enforced server-side console. Their actions run through audited `platform.*` functions; they are never given browser-reachable service-role keys. Details in RLS_SECURITY_SPECIFICATION.md §9.

---

## 8. Special states

| State | Effective permissions | Notes |
|---|---|---|
| Invited (invitation pending) | **None.** No membership row exists. | Cannot read the organisation, its name, or the invitation row. May call `get_invitation_preview(token)` and `accept_invitation(token)` only. |
| Active | As assigned | |
| Suspended | **None** in that organisation | Can still call `my_workspaces()` to learn their own status; cannot read any organisation data. Other organisations unaffected. |
| Removed / left | **None** | Rejoin only via a new invitation; the same membership row is re-activated so history keeps a stable identity. |
| Organisation `suspended`/`closing` | None for every member | Platform-controlled. |
| Role assignment expired | The assignment contributes nothing | Evaluated at query time (`expires_at > now()`). |

---

## 9. Resource access summary by role

A friendlier read of the matrix. **V** view · **E** edit · **C** create/delete · **P** publish/approve · **own** own records only · **sc** within assigned scope · **part** only where participant/assigned. Derived from §4; if the two ever disagree, §4 wins.

| Resource | Owner/Admin | Pastor | Worship Director | Dept Leader | Team Leader | Production Lead | Member |
|---|---|---|---|---|---|---|---|
| Org settings, structure | V E C | V | V | V | V | V | V (names) |
| Member directory (names/teams) | V | V | V | V | V | V | V |
| Member contact details | V | V | V | V sc | V sc | V sc | own |
| Member private notes | V E C | — | — | V E C sc | V E C sc | — | — |
| Availability (dates) | V | V | V | V sc | V sc | V sc | own V E C |
| Invitations | V C | — | V C | V C sc | — | — | — |
| Suspend / remove members | ✔ | — | — | — | — | — | — |
| Roles (custom) / assignments | V E C | — | — | assign sc | — | — | V own |
| Songs & arrangements | V E C | V | V E C | V | V | V | V |
| Internal song notes | V E C | V | V E C | — | — | — | — |
| Copyright / licence data | V E | V | V E | — | — | — | V (summary) |
| Draft services | V E C | V | V E C | part (slots) | part (slots) | V | — |
| Published services | V E P | V P | V E P | V | V | V | V |
| Service assignments | V E C | V | V E C | V E C sc | V E C sc | V E C sc | own V + respond |
| Rehearsals | V E C | V | V E C | V E C sc | V E C sc | V | part |
| Attendance records | V E | V | V E | V E sc | V E sc | V E sc | own V |
| Tasks | V E C | — | V E C | V E C sc | V E C sc | V E C sc | own V + complete |
| Announcements | V E C | V C | V C | V C sc | V C sc | V C sc | audience V |
| Channels (non-private) | V E C | — | V E C | V E C sc | V E C sc | V E C sc | per visibility |
| Direct / group / private-channel messages | **participants only** (no role can read others' DMs) | participants only | participants only | participants only | participants only | participants only | participants only |
| Message moderation (non-private channels) | ✔ | — | ✔ | ✔ sc | ✔ sc | — | report only |
| Meetings | V E C | V (minutes) | V E C | V E C sc | V E C sc | V E C | part |
| Production plans, stage plots, inputs | V E C | V | V | V sc | V sc | V E C sc | part (published) |
| Equipment inventory & allocation | V E C | V | V | — | — | V E C sc | — |
| Reports | V + export | V | V | V sc | V sc | — | own |
| Audit log | V | — | — | — | — | — | — |
| Files uploaded by others | V (via owning resource) E C | per resource | per resource | per resource | per resource | per resource | per resource |

---

## 10. Review checklist for this document

* Every permission key in RLS_SECURITY_SPECIFICATION.md §6 appears in §2 above. (Automated check described in DATABASE_TESTING_STRATEGY.md §3.9.)
* The permission count row in §4 equals the number of seed rows.
* No role other than Owner holds `org.ownership.manage`.
* No role other than Owner/Admin holds `roles.manage`, `members.suspend`, `audit.view`, `files.manage`.
* No role (including Owner, Admin and platform staff) can read a conversation of which they are not a participant.
