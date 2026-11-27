# Worship Connect — Security and Privacy Baseline

**Version:** 1.0 | **Status:** Mandatory implementation requirements

## 1. Objectives

Prevent cross-tenant access, block unauthorised or suspended users, enforce server/database permissions, protect credentials and files, secure realtime communication, minimise personal data and provide operational accountability.

This is an engineering baseline, not a legal compliance certification.

## 2. Threat model

Consider at least:
- Changing tenant IDs in browser requests.
- Guessing another tenant's resource UUID.
- Retained sessions after suspension/removal.
- Overly broad RLS policies.
- Privileged server routes using untrusted tenant IDs.
- Public storage URLs exposing recordings.
- Realtime subscriptions leaking messages.
- Leaked/reused invitation tokens.
- Malicious or oversized uploads.
- Compromised administrator accounts.
- Disclosure through logs, exports or support tools.

## 3. Authentication

Use a supported authentication provider. Secure sessions, recovery and account verification according to onboarding policy. Rate-limit sign-in, recovery and invitation flows. Never store passwords in application tables or log access tokens, refresh tokens or raw invitation tokens. Support session revocation where required. Consider stronger authentication for platform administrators and church owners.

## 4. Tenant isolation

- Enable RLS on every exposed tenant-owned table.
- Derive access from authenticated identity and active membership.
- Never trust browser-supplied tenant, membership or role identifiers.
- Validate tenant ownership across foreign-key relationships.
- Prevent cross-tenant joins and indirect access.
- Secure storage objects and realtime subscriptions independently.
- Test positive and negative access cases automatically.
- Repeat tests whenever membership logic, policies or relationships change.

A successful UI test is not evidence of tenant isolation.

## 5. Roles and scope

- Enforce permissions server-side.
- Keep roles tenant-scoped.
- Tie role assignments to active memberships.
- Limit scoped roles to assigned campus, ministry, department or team.
- Prevent self-escalation.
- Audit role changes.
- Revoke access after membership removal.
- Separate platform administration from church administration.

## 6. Privileged backend access

Supabase service-role credentials bypass RLS:
- Never expose them to browser code.
- Store them only in secure server environment configuration.
- Perform explicit authentication and authorisation before privileged queries.
- Keep privileged functions narrow.
- Review SECURITY DEFINER functions and safe search_path.
- Rotate credentials after suspected exposure.
- Never include secrets in logs or support tickets.

## 7. Files and media

Private buckets by default. Validate size and MIME type; use unpredictable paths; authorise before issuing short-lived signed URLs; apply quotas and rate limits; establish malware scanning before broad file sharing; define retention/deletion; prevent public caching of private content. A storage path is not an access control.

## 8. Chat and realtime

Verify active tenant membership, channel visibility and conversation participation. Revalidate access after reconnects. Removed members must lose future access. Realtime topic authorisation must match persisted data access. Rate-limit messages and attachments. Moderate reported content under a documented policy. Hidden channel names are not security.

## 9. Privacy and personal data

Potential data includes names, profile images, contact details, team/skill information, availability, attendance, participation, messages and recordings.

- Collect only what has a defined product purpose.
- Explain why data is collected.
- Restrict visibility by role and purpose.
- Avoid unnecessary sensitive details.
- Make emergency contact fields optional and restricted if implemented.
- Define retention, deletion and data access processes.
- Avoid exposing private notes in ordinary directories.
- Do not use participation metrics to publicly shame members.
- Obtain appropriate permission before recording or sharing people.

Obtain appropriate legal advice for applicable obligations, including South Africa's POPIA where relevant and laws in other operating jurisdictions.

## 10. Copyright and media rights

Uploading a song does not grant distribution or performance rights. Make tenant responsibilities clear, consider rights metadata and attribution, define complaint/takedown procedures and review third-party media platform terms before embedding or downloading content.

## 11. Audit logging

Audit tenant status, invitations, membership changes, role changes, sensitive settings, service publication/revisions, moderation, support access, exports and privileged administration.

Record actor, tenant, action, target, timestamp and safe metadata. Do not log credentials or unnecessary private message content.

## 12. Application security

Validate untrusted input; use parameterised database operations; protect state-changing requests against relevant CSRF risks; apply secure headers and an appropriate CSP; avoid unsafe HTML; rate-limit sensitive endpoints; update dependencies; prevent open redirects; avoid leaking stack traces; use secure cookie settings; apply least privilege.

## 13. Backups and incident readiness

Configure automated backups appropriate to the service tier. Define recovery point/time objectives and test restoration. Document incident escalation, containment, credential/session revocation and evidence handling. Communicate incidents under applicable legal and contractual requirements.

## 14. Mandatory release gate

Before a release involving tenant data:
- RLS enabled and reviewed on all exposed tenant-owned tables.
- Cross-tenant read/write tests pass.
- Suspended and removed memberships are denied.
- Role escalation tests pass.
- Storage and realtime access tests pass where used.
- No privileged secret is exposed to the client.
- Sensitive actions are audited.
- Preview and production are separated.
- Backup and recovery expectations are documented.

## 15. Minimum test scenarios

Use at least Tenant A and Tenant B:
1. Active A member accesses permitted A resources.
2. A member cannot read B resources.
3. A member cannot insert, update or delete B resources.
4. Non-member cannot access private tenant resources.
5. Suspended/removed member loses access.
6. A role does not grant permissions in B.
7. Scoped leader cannot administer outside scope.
8. User cannot change own role by direct API call.
9. Storage URL cannot bypass access policy.
10. Realtime cannot leak cross-tenant events.
11. Privileged route rejects unauthorised callers before elevated access.
