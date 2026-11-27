-- M-010: global user profile (one per person) and the signup trigger.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  display_name       text not null check (char_length(display_name) between 1 and 100),
  preferred_timezone text check (preferred_timezone is null or private.is_valid_timezone(preferred_timezone)),
  locale             text not null default 'en' check (locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
  avatar_path        text,
  terms_accepted_at  timestamptz,
  terms_version      text,
  anonymised_at      timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.profiles force row level security;
create trigger profiles_set_updated_at before update on public.profiles for each row execute function private.set_updated_at();

-- Create the profile when an auth user is created. E-mail/credentials stay in auth.users (not duplicated).
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(nullif(btrim(new.raw_user_meta_data->>'display_name'), ''),
                                nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Member'), 100))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.handle_new_user();
