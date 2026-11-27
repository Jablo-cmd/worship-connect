-- M-011: the tenant (organisation) and its settings.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.organisations (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (char_length(name) between 1 and 120),
  slug                 extensions.citext not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  status               text not null default 'active' check (status in ('active','suspended','closing','closed')),
  status_changed_at    timestamptz not null default now(),
  timezone             text not null check (private.is_valid_timezone(timezone)),
  country_code         char(2) check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  contact_email        extensions.citext check (contact_email is null or contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_phone        text check (contact_phone is null or char_length(contact_phone) <= 40),
  website_url          text check (website_url is null or website_url ~ '^https://'),
  created_by           uuid references public.profiles (id) on delete set null,
  closing_requested_at timestamptz,
  scheduled_purge_at   timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index organisations_created_by_idx on public.organisations (created_by);
alter table public.organisations enable row level security;
alter table public.organisations force row level security;
create trigger organisations_set_updated_at before update on public.organisations for each row execute function private.set_updated_at();

-- slug is immutable after creation.
create or replace function private.forbid_slug_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.slug is distinct from old.slug then raise exception 'slug is immutable' using errcode = '42501'; end if;
  return new;
end $$;
create trigger organisations_forbid_slug_change before update on public.organisations for each row execute function private.forbid_slug_change();

create table public.organisation_settings (
  organisation_id                  uuid primary key references public.organisations (id) on delete cascade,
  locale                           text not null default 'en',
  week_starts_on                   smallint not null default 0 check (week_starts_on between 0 and 6),
  default_service_duration_minutes integer not null default 90 check (default_service_duration_minutes between 15 and 600),
  member_directory_visibility      text not null default 'names_and_teams' check (member_directory_visibility in ('names_only','names_and_teams')),
  allow_direct_messages            boolean not null default true,
  require_mfa_for_privileged       boolean not null default false,   -- inert extension point (D-027 deferred); nothing enforces it yet
  message_retention_days           integer check (message_retention_days is null or message_retention_days > 0),
  attendance_retention_months      integer check (attendance_retention_months is null or attendance_retention_months > 0),
  logo_file_id                     uuid,                              -- FK added with the files registry (M-018)
  ui_flags                         jsonb not null default '{}'::jsonb, -- COSMETIC ONLY: never read by RLS or authorisation
  created_at                       timestamptz not null default now(),
  updated_at                       timestamptz not null default now()
);
alter table public.organisation_settings enable row level security;
alter table public.organisation_settings force row level security;
create trigger organisation_settings_set_updated_at before update on public.organisation_settings for each row execute function private.set_updated_at();
create trigger organisation_settings_forbid_org_change before update on public.organisation_settings
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();
