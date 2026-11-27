-- M-026: CORRECTIVE (found by CAT-08). invitation_tokens and invitation_teams referenced invitations(id) with a
-- single-column foreign key, so a row's organisation_id was not pinned to its invitation's. Replace with composite
-- (organisation_id, invitation_id) keys (cascading on delete) so the tenant-integrity guarantee holds everywhere.
set lock_timeout = '10s';
set statement_timeout = '60s';

alter table public.invitation_tokens drop constraint invitation_tokens_invitation_id_fkey;
alter table public.invitation_tokens add constraint invitation_tokens_invitation_fk
  foreign key (organisation_id, invitation_id) references public.invitations (organisation_id, id) on delete cascade;

alter table public.invitation_teams drop constraint invitation_teams_invitation_id_fkey;
alter table public.invitation_teams drop constraint invitation_teams_organisation_id_invitation_id_fkey;
alter table public.invitation_teams add constraint invitation_teams_invitation_fk
  foreign key (organisation_id, invitation_id) references public.invitations (organisation_id, id) on delete cascade;
