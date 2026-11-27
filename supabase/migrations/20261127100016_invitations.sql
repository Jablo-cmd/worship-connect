-- M-016: invitations. The token hash lives in a SERVER-ONLY table (column-level REVOKE is ineffective while a
-- table-level grant exists, and a column-list grant breaks `select *` - spike S-5).
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  email extensions.citext not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status text not null default 'pending' check (status in ('pending','accepted','revoked','expired')),
  role_id uuid references public.roles (id),
  scope_type text not null default 'organisation' check (scope_type in ('organisation','campus','ministry','department','team')),
  campus_id uuid, ministry_id uuid, department_id uuid, team_id uuid,
  invited_by_membership_id uuid not null,
  personal_message text check (personal_message is null or char_length(personal_message) <= 500),
  expires_at timestamptz not null default (now() + interval '14 days'),
  send_count smallint not null default 1,
  last_sent_at timestamptz not null default now(),
  accepted_by_user_id uuid references public.profiles (id) on delete set null,
  accepted_membership_id uuid,
  accepted_at timestamptz,
  revoked_at timestamptz,
  revoked_by_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, campus_id)     references public.campuses (organisation_id, id),
  foreign key (organisation_id, ministry_id)   references public.ministries (organisation_id, id),
  foreign key (organisation_id, department_id) references public.departments (organisation_id, id),
  foreign key (organisation_id, team_id)       references public.teams (organisation_id, id),
  foreign key (organisation_id, invited_by_membership_id) references public.memberships (organisation_id, id),
  foreign key (organisation_id, accepted_membership_id)   references public.memberships (organisation_id, id),
  foreign key (organisation_id, revoked_by_membership_id) references public.memberships (organisation_id, id),
  check ( (scope_type = 'organisation' and num_nonnulls(campus_id, ministry_id, department_id, team_id) = 0)
       or (scope_type = 'campus'     and campus_id     is not null and num_nonnulls(ministry_id, department_id, team_id) = 0)
       or (scope_type = 'ministry'   and ministry_id   is not null and num_nonnulls(campus_id, department_id, team_id) = 0)
       or (scope_type = 'department' and department_id is not null and num_nonnulls(campus_id, ministry_id, team_id) = 0)
       or (scope_type = 'team'       and team_id       is not null and num_nonnulls(campus_id, ministry_id, department_id) = 0) ),
  check (expires_at <= created_at + interval '60 days'),
  check (status <> 'accepted' or (accepted_at is not null and accepted_membership_id is not null)),
  check (status <> 'revoked'  or revoked_at is not null)
);
create unique index invitations_pending_uq on public.invitations (organisation_id, email) where status = 'pending';
create index invitations_inviter_idx on public.invitations (organisation_id, invited_by_membership_id);
alter table public.invitations enable row level security;
alter table public.invitations force row level security;
create trigger invitations_set_updated_at before update on public.invitations for each row execute function private.set_updated_at();
create trigger invitations_forbid_org_change before update on public.invitations
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();
-- The optional extra role must be global or belong to this organisation, and be assignable at the invitation's scope.
create or replace function private.check_invitation_role() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r public.roles;
begin
  select * into r from public.roles where id = new.role_id and archived_at is null;
  if not found or (r.organisation_id is not null and r.organisation_id <> new.organisation_id)
     or not (new.scope_type = any (r.assignable_scopes)) then
    raise exception 'role is not available for this invitation' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger invitations_check_role_org_ins before insert on public.invitations
  for each row when (new.role_id is not null) execute function private.check_invitation_role();

create table public.invitation_tokens (
  invitation_id uuid primary key references public.invitations (id) on delete cascade,
  organisation_id uuid not null references public.organisations (id),
  token_hash bytea not null unique,        -- SHA-256 of a 256-bit random token; the raw token is returned once and never stored
  created_at timestamptz not null default now()
);
alter table public.invitation_tokens enable row level security;
alter table public.invitation_tokens force row level security;
-- No policies and no grants: unreachable by anon/authenticated; used only by SECURITY DEFINER invitation functions.

create table public.invitation_teams (
  organisation_id uuid not null,
  invitation_id uuid not null references public.invitations (id) on delete cascade,
  team_id uuid not null,
  primary key (invitation_id, team_id),
  foreign key (organisation_id, team_id) references public.teams (organisation_id, id),
  foreign key (organisation_id, invitation_id) references public.invitations (organisation_id, id)
);
alter table public.invitation_teams enable row level security;
alter table public.invitation_teams force row level security;
