-- M-014: a person's membership of one church, its lifecycle history, contact details, policy acceptances, team rosters.
-- (team_memberships is created here rather than in Phase 2 because scope helpers and invitations depend on it.)
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  user_id uuid references public.profiles (id) on delete set null,
  status text not null default 'active' check (status in ('active','suspended','removed')),   -- no 'invited': D-021
  display_name text not null check (char_length(display_name) between 1 and 100),
  avatar_file_id uuid,                                    -- FK added with the files registry (M-018)
  home_campus_id uuid,
  joined_at timestamptz not null default now(),
  status_changed_at timestamptz not null default now(),
  anonymised_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  unique (organisation_id, user_id),
  foreign key (organisation_id, home_campus_id) references public.campuses (organisation_id, id),
  check (user_id is not null or (status = 'removed' and anonymised_at is not null))
);
-- Hot path for EVERY RLS check:
create index memberships_user_active_idx on public.memberships (user_id, organisation_id) where status = 'active';
create index memberships_org_status_idx  on public.memberships (organisation_id, status);
create index memberships_campus_idx      on public.memberships (organisation_id, home_campus_id);
alter table public.memberships enable row level security;
alter table public.memberships force row level security;
create trigger memberships_set_updated_at before update on public.memberships for each row execute function private.set_updated_at();
create trigger memberships_forbid_org_change before update on public.memberships
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();

create table public.membership_status_events (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  membership_id uuid not null,
  from_status text,
  to_status text not null,
  reason text check (reason is null or char_length(reason) <= 500),   -- restricted: why it is not a column of memberships
  actor_user_id uuid references public.profiles (id) on delete set null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, membership_id) references public.memberships (organisation_id, id)
);
create index membership_status_events_idx on public.membership_status_events (organisation_id, membership_id, occurred_at desc);
alter table public.membership_status_events enable row level security;
alter table public.membership_status_events force row level security;
create trigger membership_status_events_block before update or delete on public.membership_status_events for each row execute function private.block_mutation();

create table public.membership_contacts (
  membership_id uuid primary key,
  organisation_id uuid not null,
  phone text check (phone is null or char_length(phone) <= 40),
  contact_email extensions.citext check (contact_email is null or contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  preferred_method text check (preferred_method is null or preferred_method in ('in_app','email','phone','whatsapp')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id, membership_id) references public.memberships (organisation_id, id)
);
alter table public.membership_contacts enable row level security;
alter table public.membership_contacts force row level security;
create trigger membership_contacts_set_updated_at before update on public.membership_contacts for each row execute function private.set_updated_at();

create table public.policy_acceptances (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  membership_id uuid not null,
  policy_key text not null check (policy_key in ('music_rights','recording_consent','privacy_notice','terms')),
  policy_version text not null check (char_length(policy_version) between 1 and 40),
  accepted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, membership_id) references public.memberships (organisation_id, id),
  unique (membership_id, policy_key, policy_version)
);
alter table public.policy_acceptances enable row level security;
alter table public.policy_acceptances force row level security;
create trigger policy_acceptances_block before update or delete on public.policy_acceptances for each row execute function private.block_mutation();

create table public.team_memberships (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  team_id uuid not null,
  membership_id uuid not null,
  status text not null default 'active' check (status in ('active','inactive','alumni')),
  joined_on date not null default current_date,
  left_on date,
  added_by_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  unique (team_id, membership_id),
  check (left_on is null or left_on >= joined_on),
  foreign key (organisation_id, team_id) references public.teams (organisation_id, id),
  foreign key (organisation_id, membership_id) references public.memberships (organisation_id, id),
  foreign key (organisation_id, added_by_membership_id) references public.memberships (organisation_id, id)
);
create index team_memberships_member_idx on public.team_memberships (membership_id, team_id) where status = 'active';
create index team_memberships_team_idx   on public.team_memberships (organisation_id, team_id);
alter table public.team_memberships enable row level security;
alter table public.team_memberships force row level security;
create trigger team_memberships_set_updated_at before update on public.team_memberships for each row execute function private.set_updated_at();
create trigger team_memberships_forbid_org_change before update on public.team_memberships
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();

-- The referenced membership must be ACTIVE when a roster row is created/changed.
create or replace function private.check_active_membership() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.memberships m where m.id = new.membership_id and m.organisation_id = new.organisation_id and m.status = 'active') then
    raise exception 'membership is not active' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger team_memberships_check_active before insert on public.team_memberships for each row execute function private.check_active_membership();
