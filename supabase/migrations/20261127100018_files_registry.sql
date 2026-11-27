-- M-018: file registry, private storage bucket and its policies. Uploads are PRE-REGISTERED; the storage path is an
-- identifier, never an authorisation. Reads consult the registry (status, scan, relationship) and live membership.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.files (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  uploaded_by_user_id uuid references public.profiles (id) on delete set null,
  bucket text not null default 'org-files' check (bucket = 'org-files'),
  storage_path text not null unique,
  original_filename text not null check (char_length(original_filename) between 1 and 255),
  mime_type text not null check (mime_type in ('application/pdf','image/png','image/jpeg','image/webp','image/gif','audio/mpeg','audio/mp4','audio/wav','audio/ogg','audio/webm','video/mp4','video/webm','text/plain')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 52428800),
  sha256 bytea,
  purpose text not null check (purpose in ('song_resource','message_attachment','voice_note','meeting_document','service_file','rehearsal_recording','production_document','stage_plot_background','member_avatar','org_logo','report_export','permission_document','other')),
  status text not null default 'pending_upload' check (status in ('pending_upload','uploaded','available','quarantined','rejected','deleted')),
  scan_status text not null default 'not_scanned' check (scan_status in ('not_scanned','clean','infected','error','not_required')),
  scanned_at timestamptz, deleted_at timestamptz, retention_until timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  check (storage_path = organisation_id::text || '/' || id::text || '/' || split_part(storage_path, '/', 3))
);
create index files_org_purpose_idx on public.files (organisation_id, purpose, created_at desc);
create index files_uploader_idx    on public.files (uploaded_by_user_id);
alter table public.files enable row level security;
alter table public.files force row level security;
create trigger files_set_updated_at before update on public.files for each row execute function private.set_updated_at();
create trigger files_forbid_org_change before update on public.files
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();

alter table public.organisation_settings add constraint organisation_settings_logo_fk
  foreign key (organisation_id, logo_file_id) references public.files (organisation_id, id);
alter table public.memberships add constraint memberships_avatar_fk
  foreign key (organisation_id, avatar_file_id) references public.files (organisation_id, id);

-- File access: uploader only in Phase 1. LATER PHASES EXTEND THIS FUNCTION with relationships (message attachments via
-- conversation access, song resources via access_scope, ...). `files.manage` is deliberately NOT a read path: with it,
-- an Owner/Admin could open a DM attachment or any unattached file (found by a failing test on Supabase).
create or replace function private.can_read_file(p_file uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.files f
    where f.id = p_file and f.status = 'available' and f.scan_status in ('clean','not_required')
      and private.is_member(f.organisation_id)
      and f.uploaded_by_user_id = (select auth.uid())) $$;

create or replace function private.can_upload_registered_object(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.files f
    where f.storage_path = p_name
      and f.id = private.try_uuid((string_to_array(p_name, '/'))[2])
      and f.organisation_id = private.try_uuid((string_to_array(p_name, '/'))[1])
      and f.status = 'pending_upload' and f.uploaded_by_user_id = (select auth.uid())
      and private.is_member(f.organisation_id)) $$;
grant execute on function private.can_read_file(uuid), private.can_upload_registered_object(text) to authenticated, service_role;

-- Private bucket; limits here are defence in depth (the RPC enforces per-purpose limits).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('org-files', 'org-files', false, 52428800,
        array['application/pdf','image/png','image/jpeg','image/webp','image/gif','audio/mpeg','audio/mp4','audio/wav','audio/ogg','audio/webm','video/mp4','video/webm','text/plain'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy org_files_read on storage.objects for select to authenticated
  using ( bucket_id = 'org-files'
          and private.can_read_file(private.try_uuid((storage.foldername(name))[2]))
          and private.try_uuid((storage.foldername(name))[1]) =
              (select f.organisation_id from public.files f where f.id = private.try_uuid((storage.foldername(name))[2])) );
create policy org_files_insert on storage.objects for insert to authenticated
  with check ( bucket_id = 'org-files' and private.can_upload_registered_object(name) );
-- No UPDATE or DELETE policy: no client overwrite (x-upsert) and no client deletion. Removal is a server job.
