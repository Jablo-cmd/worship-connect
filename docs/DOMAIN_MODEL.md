# Worship Connect — Domain Model

**Version:** 1.0 | **Status:** Conceptual model; SQL schema and policies require separate design review.

## 1. Modelling principles

- One global identity can participate in multiple churches.
- A church is a tenant boundary.
- Membership joins a global user to a tenant.
- Roles are tenant-specific unless explicitly platform-level.
- Organisation levels are optional.
- Services connect people, teams, songs, rehearsals and production.
- Historical service snapshots remain understandable after catalogue edits.

## 2. Identity and tenancy

### User Profile
Application profile associated with the authentication identity: id (auth user ID), display_name, avatar_path, preferred_timezone, created_at, updated_at. Credentials remain with the auth provider.

### Tenant
Church workspace: id, name, slug, status, timezone, contact_email, created_at, updated_at.

### Membership
Joins user to tenant: id, tenant_id, user_id, status (invited/active/suspended/removed), joined_at, timestamps. Define uniqueness and historical membership policy.

### Invitation
Tenant invitation: id, tenant_id, invited_email, invited_by_membership_id, intended_role_id (optional), token_hash, status, expires_at, accepted_by_user_id, accepted_at, created_at. Store secure token hashes, not raw secrets.

## 3. Roles and permissions

- **Permission:** stable identifier and description.
- **Role:** tenant-owned or controlled platform role, name, description, system-role flag.
- **Role Permission:** join between roles and permissions.
- **Membership Role Assignment:** tenant_id, membership_id, role_id, scope_type (tenant/campus/ministry/department/team), scope_id, created_by and timestamp.

Validate that membership, role and scoped resource belong to the same tenant. Platform permissions must remain separate from ordinary church roles.

## 4. Organisation

- **Campus:** optional church branch/location.
- **Ministry:** ministry or operating area.
- **Department:** functional division such as band, vocals, choir, audio or media.
- **Team:** working group.
- **Team Membership:** links a church membership to a team with team-specific status or position.

Allow simple structures without every hierarchy level. A person may belong to multiple teams; do not duplicate their global identity or tenant membership.

## 5. Member capabilities

- **Member Skill:** tenant_id, membership_id, skill type/name, optional proficiency and restricted notes.
- **Availability:** tenant_id, membership_id, starts_at, ends_at, availability type and optional restricted note.

Leaders generally need availability status, not unnecessary private explanations. Define proficiency criteria before presenting ratings as objective.

## 6. Music domain

### Song
Tenant-owned catalogue entry: title, artist, alternate titles, default key/BPM, time signature, language, tags, description, status and audit fields.

### Song Arrangement
Named church performance version: song_id, name, key, BPM, time signature, notes, version and status.

### Arrangement Section
Ordered section: arrangement_id, position, section_type, label, repeat_count and notes. Examples: intro, verse, chorus, bridge, instrumental, vamp, tag and outro.

### Song Resource
Chart, lyric document, recording or external reference: song_id, optional arrangement_id, resource type, private storage path or external URL, title and access scope.

Consider copyright, licensing, attribution, ownership and retention before storing or distributing lyrics and recordings.

## 7. Services and programme

### Service
Tenant, optional campus, title/type, starts_at, ends_at, timezone, venue, status (draft/published/completed/cancelled), created_by, published_at and version.

### Service Programme Item
Ordered item: service_id, position, item_type (song/prayer/scripture/announcement/transition/other), title, instructions and optional duration.

### Service Song
Service-specific song and arrangement reference, performance key/BPM, notes and snapshot metadata. Do not silently rewrite a published service when the catalogue changes.

### Service Assignment
Assigns a membership or team to a service role. Define whether assignment is person-specific or team-level; prevent ambiguous records.

### Service Revision
Version, service_id, changed_by, change summary, snapshot and created_at for meaningful published changes.

## 8. Scheduling and rehearsal

- **Rehearsal:** tenant, optional service, title, starts/ends, timezone, location, status, agenda and creator.
- **Rehearsal Participant:** invited membership or team.
- **Attendance Record:** tenant, event reference, membership, status, optional arrival time, recorder and correction history.
- **Rehearsal Note:** note linked to rehearsal, song or arrangement.
- **Practice Task:** assigned member/team, due date and completion status.

Controlled attendance states may include present, late, absent, excused and not_recorded. Define correction and audit behaviour.

## 9. Communication

- **Channel:** tenant, name, type (announcement/team/department/service/rehearsal), visibility and optional linked resource.
- **Channel Membership:** authorised channel participants.
- **Message:** tenant, channel or conversation, sender membership, type, body, optional parent message, edit/delete metadata and timestamp.
- **Conversation / Participant:** direct or group direct message; initial design should prohibit cross-tenant conversations.
- **Message Attachment:** validated metadata and private storage reference.
- **Message Reaction:** reaction and membership.

Define retention, editing, deletion, moderation and export policy.

## 10. Meetings and tasks

- **Meeting:** tenant, schedule and optional department/team relationship.
- **Meeting Participant:** invited membership.
- **Meeting Agenda Item:** ordered agenda entry.
- **Meeting Minute:** restricted meeting record.
- **Decision:** decision, author, date and context.
- **Action Item:** owner, due date, status and optional linked meeting/service.

## 11. Production

- **Production Plan:** service-specific technical plan.
- **Stage Position:** labelled position or coordinates.
- **Production Assignment:** person/team responsibility.
- **Audio Input:** input channel, source, connection type and notes.
- **Monitor Requirement:** performer/position monitor needs.
- **Equipment Checklist Item:** setup/strike task, owner and status.
- **Production Cue:** lighting, projection, media or timed instruction.

Templates may be reused, but each service should preserve its own configuration snapshot.

## 12. Notifications and audit

- **Notification:** recipient, event type, target and read state.
- **Notification Preference:** channel/category preferences.
- **Delivery Attempt:** email/push status and retry information.
- **Audit Event:** actor, tenant (nullable for platform events), action, resource type/id, safe metadata and timestamp.

Do not store credentials, raw tokens or unnecessary private content in audit metadata.

## 13. Relationship overview

```text
Auth User
  |-- User Profile
  |-- Membership -- Tenant
        |-- Role Assignments -- Roles -- Permissions
        |-- Team Memberships -- Teams -- Departments / Ministries / Campuses
        |-- Skills and Availability
        |-- Service Assignments -- Service
        |      |-- Programme Items -- Songs -- Arrangements
        |      |-- Rehearsals
        |      |-- Production Plan
        |-- Channel Memberships -- Channels -- Messages
        |-- Meeting Participation -- Meetings -- Action Items
        |-- Attendance Records
```

## 14. Schema implementation checklist

Before migrations:
1. Confirm tenant ownership of every entity.
2. Define deletion and retention.
3. Define foreign keys and unique constraints.
4. Define indexes for common queries.
5. Define role and scope semantics.
6. Write RLS policies with the tables.
7. Test policies across tenant and membership states.
8. Add local-only seed data.
9. Document intentional denormalisation.
10. Do not create every conceptual table in one unreviewed migration.

## 15. Open modelling questions

- Are campuses required in first release?
- Can services span campuses?
- Can team leaders accept assignments on behalf of a team?
- Are channel permissions role-based, membership-based or both?
- What are message retention and export rules?
- How is song licensing represented?
- How are stage layouts stored and versioned?
- Should service and rehearsal attendance share an event abstraction?
