-- M-028: CORRECTIVE (found by CAT-10). memberships.user_id (FK to profiles, ON DELETE SET NULL) was covered only by a
-- PARTIAL index (status = 'active'), which cannot serve the referential check for suspended/removed rows.
set lock_timeout = '10s';
set statement_timeout = '60s';
create index if not exists memberships_user_idx on public.memberships (user_id);
