# Worship Connect — User Workflows

**Version:** 1.0 | **Status:** Initial UX baseline

## 1. Experience principles

- Show users what they need to do next.
- Make common member actions fast on mobile.
- Do not overwhelm small churches with enterprise setup.
- Make the active church workspace obvious.
- Distinguish draft, published and completed information.
- Highlight pending responses and assignments.
- Connect service, music, rehearsal and production information.
- Explain errors and next actions.
- Provide loading, empty, success and error states.

## 2. Role-aware navigation

Possible navigation:
- Home
- Services
- Calendar
- Music Library
- Rehearsals
- Teams & Members
- Chat
- Meetings
- Production
- Reports
- Workspace Settings

Show only features the user can access. Member navigation should be simpler than administrator navigation.

## 3. Church owner onboarding

1. Open registration and create/sign into an account.
2. Create a church workspace.
3. Enter church name, timezone and contact details.
4. Create workspace and owner membership.
5. Review suggested simple organisation.
6. Optionally add campus, ministry, department or team.
7. Invite leaders and members.
8. Review onboarding checklist.
9. Create first service or return later.

Optional organisation steps must be skippable.

## 4. Invitation acceptance

1. Receive invitation identifying church and inviter.
2. Sign in or create account.
3. Validate invitation token and expiry.
4. Accept invitation.
5. Activate membership.
6. Enter correct church workspace.
7. Complete requested profile details.

Expired, revoked and used invitations need clear recovery guidance.

## 5. Workspace switching

1. Open workspace selector.
2. Show only the user's memberships.
3. Select church.
4. Server validates active membership.
5. Update workspace context and navigation.
6. Clear stale data from the previous workspace.

## 6. Weekly service lifecycle

### Create
Director creates service with title, date, start/end, timezone, campus and venue; saves draft.

### Build
Add ordered programme items; select songs and arrangements; confirm key, tempo and notes; add transitions and non-song items.

### Assign
Add roles/teams; assign people; review availability, conflicts and unfilled roles; send invitations.

### Publish
Review plan; publish; notify affected members; record published revision as current source of truth.

### Change
Authorised leader edits; system identifies material changes; records new revision; notifies affected members; preserves previous revision.

## 7. Member preparation

1. Open Home or Calendar.
2. Review upcoming services and response status.
3. Open service and review arrival time and role.
4. Accept, decline or mark tentative.
5. Open assigned songs or technical instructions.
6. Review resources and notes.
7. Complete preparation tasks.
8. Receive relevant updates.

## 8. Rehearsal workflow

1. Leader creates rehearsal, optionally linked to service.
2. Sets date, time, venue and participants.
3. Adds agenda and songs/sections.
4. Sends invitations.
5. Members respond.
6. Leader records attendance.
7. Captures song-specific issues.
8. Assigns practice tasks.
9. Marks rehearsal complete.
10. Outstanding follow-ups remain visible.

## 9. Role-specific workspaces

### Musician
Upcoming service/rehearsal, instrument assignment, songs, key/BPM, arrangement sections, charts, recordings, music director notes and preparation checklist.

### Vocalist / choir
Vocal role, lead/harmony assignment, song order, lyrics and permitted resources, key, arrangement, vocal notes/cues and practice recordings.

### Sound / production
Service requirements, stage plot, input list, microphones, DI, monitor needs, cues, checklists and soundcheck status.

## 10. Production workflow

1. Production lead opens service.
2. Reviews technical responsibilities.
3. Opens stage plot and input list.
4. Reviews microphone, DI and monitor needs.
5. Reviews media, lighting and livestream cues.
6. Assigns checklist items.
7. Operators mark work complete.
8. Lead records soundcheck readiness.
9. Relevant service changes update the technical plan.

## 11. Chat workflow

1. Open Chat.
2. See authorised channels.
3. Open team, department or service discussion.
4. Send message or attachment.
5. Notify members according to preferences.
6. Search and pin relevant information.
7. Moderators handle reports under policy.

Service discussions should be linked to the service.

## 12. Meeting workflow

1. Schedule meeting.
2. Select participants and department.
3. Add agenda.
4. Record minutes and decisions.
5. Create action items with owners and due dates.
6. Notify participants.
7. Track outstanding work.

## 13. Post-service workflow

1. Mark service completed.
2. Finalise attendance.
3. Capture operational issues.
4. Record production/rehearsal follow-ups.
5. Assign actions.
6. Preserve service as historical reference.
7. Update reports according to access permissions.

## 14. Exception and empty states

Design explicit states for no membership, no upcoming service, no assigned songs, pending/declined invitation, unfilled role, cancelled rehearsal, changed published service, offline state, expired invitation, suspended/removed membership, inaccessible channel, upload failure and notification delivery failure.

Always explain the next available action rather than displaying a blank screen or generic error.
