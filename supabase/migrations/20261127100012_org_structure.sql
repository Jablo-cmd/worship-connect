-- M-012: optional hierarchy Campus -> Ministry -> Department -> Team, plus locations.
-- Every level is optional. Ancestor columns are DERIVED by trigger from the lowest level set (never trusted from clients).
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.campuses (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  name text not null check (char_length(name) between 1 and 100),
  code text check (code is null or char_length(code) <= 20),
  address_line text, city text, region text, postal_code text,
  country_code char(2) check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  timezone text check (timezone is null or private.is_valid_timezone(timezone)),
  is_primary boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id)
);
create unique index campuses_name_uq on public.campuses (organisation_id, lower(name)) where archived_at is null;
create unique index campuses_one_primary_uq on public.campuses (organisation_id) where is_primary and archived_at is null;

create table public.ministries (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  name text not null check (char_length(name) between 1 and 100),
  description text check (description is null or char_length(description) <= 1000),
  campus_id uuid,
  archived_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, campus_id) references public.campuses (organisation_id, id)
);
create unique index ministries_name_uq on public.ministries (organisation_id, lower(name)) where archived_at is null;
create index ministries_campus_idx on public.ministries (organisation_id, campus_id);

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  name text not null check (char_length(name) between 1 and 100),
  description text check (description is null or char_length(description) <= 1000),
  category text check (category is null or category in ('band','vocal','choir','orchestra','sound','lighting','media','projection','livestream','stage','hospitality','prayer','administration','other')),
  ministry_id uuid, campus_id uuid,
  archived_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, ministry_id) references public.ministries (organisation_id, id),
  foreign key (organisation_id, campus_id)   references public.campuses (organisation_id, id)
);
create unique index departments_name_uq on public.departments (organisation_id, coalesce(ministry_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name)) where archived_at is null;
create index departments_ministry_idx on public.departments (organisation_id, ministry_id);
create index departments_campus_idx   on public.departments (organisation_id, campus_id);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  name text not null check (char_length(name) between 1 and 100),
  description text check (description is null or char_length(description) <= 1000),
  category text not null default 'other' check (category in ('band','vocal','choir','orchestra','sound','lighting','media','projection','livestream','stage','hospitality','prayer','administration','other')),
  department_id uuid, ministry_id uuid, campus_id uuid,
  archived_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, department_id) references public.departments (organisation_id, id),
  foreign key (organisation_id, ministry_id)   references public.ministries (organisation_id, id),
  foreign key (organisation_id, campus_id)     references public.campuses (organisation_id, id)
);
create unique index teams_name_uq on public.teams (organisation_id, coalesce(department_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name)) where archived_at is null;
create index teams_department_idx on public.teams (organisation_id, department_id);
create index teams_ministry_idx   on public.teams (organisation_id, ministry_id);
create index teams_campus_idx     on public.teams (organisation_id, campus_id);

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  campus_id uuid,
  name text not null check (char_length(name) between 1 and 100),
  kind text not null default 'other' check (kind in ('sanctuary','rehearsal_room','hall','outdoor','online','offsite','other')),
  room text, address_text text,
  capacity integer check (capacity is null or capacity > 0),
  online_url text check (online_url is null or online_url ~ '^https://'),
  timezone text check (timezone is null or private.is_valid_timezone(timezone)),
  archived_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, campus_id) references public.campuses (organisation_id, id)
);
create index locations_campus_idx on public.locations (organisation_id, campus_id);

-- Derive/validate ancestors from the LOWEST level set. Inconsistent combinations are rejected.
create or replace function private.fill_scope_ancestors() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d public.departments; mi public.ministries;
begin
  if tg_table_name = 'teams' then
    if new.department_id is not null then
      select * into d from public.departments where id = new.department_id and organisation_id = new.organisation_id;
      if not found then raise exception 'department not found in organisation' using errcode = '23503'; end if;
      if new.ministry_id is not null and new.ministry_id is distinct from d.ministry_id then
        raise exception 'ministry does not match department' using errcode = '23514'; end if;
      if new.campus_id is not null and new.campus_id is distinct from d.campus_id then
        raise exception 'campus does not match department' using errcode = '23514'; end if;
      new.ministry_id := d.ministry_id; new.campus_id := d.campus_id;
    elsif new.ministry_id is not null then
      select * into mi from public.ministries where id = new.ministry_id and organisation_id = new.organisation_id;
      if not found then raise exception 'ministry not found in organisation' using errcode = '23503'; end if;
      if new.campus_id is not null and new.campus_id is distinct from mi.campus_id then
        raise exception 'campus does not match ministry' using errcode = '23514'; end if;
      new.campus_id := mi.campus_id;
    end if;
  elsif tg_table_name = 'departments' then
    if new.ministry_id is not null then
      select * into mi from public.ministries where id = new.ministry_id and organisation_id = new.organisation_id;
      if not found then raise exception 'ministry not found in organisation' using errcode = '23503'; end if;
      if new.campus_id is not null and new.campus_id is distinct from mi.campus_id then
        raise exception 'campus does not match ministry' using errcode = '23514'; end if;
      new.campus_id := mi.campus_id;
    end if;
  end if;
  return new;
end $$;
create trigger departments_fill_ancestors before insert or update on public.departments for each row execute function private.fill_scope_ancestors();
create trigger teams_fill_ancestors       before insert or update on public.teams       for each row execute function private.fill_scope_ancestors();

do $$ declare t text; begin
  foreach t in array array['campuses','ministries','departments','teams','locations'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('create trigger %I before update on public.%I for each row execute function private.set_updated_at()', t || '_set_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change()', t || '_forbid_org_change', t);
  end loop;
end $$;
