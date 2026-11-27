# Worship Connect — Decision Log

Record confirmed direction, provisional decisions and open questions here. Update this file when a decision changes.

**Statuses:** Accepted, Proposed, Open, Superseded.

## Accepted direction

### D-001 — Multi-tenant SaaS
**Status:** Accepted  
Design for multiple independent church tenants from the beginning. Tenant isolation is foundational and expensive to retrofit.

### D-002 — Global identity, multiple memberships
**Status:** Accepted  
One global user identity may have different memberships and roles in multiple churches.

### D-003 — Flexible organisational hierarchy
**Status:** Accepted  
Support optional campuses, ministries, departments and teams. Small churches must not be forced into enterprise structure.

### D-004 — Cross-department service collaboration
**Status:** Accepted  
Departments and teams collaborate on shared church services while retaining appropriate scoped permissions.

### D-005 — End-to-end worship operations
**Status:** Accepted  
Scope includes people, music, services, rehearsals, communication, meetings and technical production.

### D-006 — Database and server-side security
**Status:** Accepted  
Use PostgreSQL RLS and server-side authorisation. Frontend-only checks are insufficient.

## Proposed technical decisions

### D-007 — Modular monolith
**Status:** Proposed  
Start with modular Next.js application and PostgreSQL backend, not microservices. Reassess when measured requirements justify separation.

### D-008 — Initial stack
**Status:** Proposed  
Next.js, TypeScript, Supabase Auth, PostgreSQL, RLS, Realtime, Storage, Tailwind, shadcn/ui and Vercel. Validate provider limits, pricing and compatibility before production.

### D-009 — Private file storage
**Status:** Proposed  
Private buckets with authorised access and short-lived signed URLs by default.

### D-010 — In-app notifications first
**Status:** Proposed  
Establish internal notification model before multiple external delivery providers.

### D-011 — Responsive web first
**Status:** Proposed  
Mobile-first responsive web experience; defer native apps until product validation.

## Open decisions

### D-012 — Final brand
Is Worship Connect the final public name? Confirm visual identity, domain and tagline.

### D-013 — Onboarding
Self-service church registration, invitation-led registration or approval/verification?

### D-014 — Campus scope
Include campus management in first production release or later?

### D-015 — Billing
Provider, free tier, pricing dimensions, limits, trial and grace-period behaviour?

### D-016 — Music rights
What content may tenants store? What rights metadata and takedown process are needed?

### D-017 — Chat policy
Retention, editing/deletion, export, moderation and voice-note limits?

### D-018 — Native apps
What adoption and usage evidence justifies Android and iOS apps?

## Changing a decision

1. Add or update a decision with reason.
2. Identify affected docs, code and migrations.
3. Document migration and compatibility implications.
4. Update product and architecture specifications.
5. Do not silently implement a conflicting approach.
