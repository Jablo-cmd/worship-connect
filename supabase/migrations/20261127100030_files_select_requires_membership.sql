-- M-030: the "uploader sees own registry row" branch must also require an active membership,
-- otherwise a suspended/removed member keeps reading their own file rows (found by MEM-06 in CI).
drop policy if exists files_select on public.files;
create policy files_select on public.files for select to authenticated
  using (private.can_read_file(id)
         or (uploaded_by_user_id = (select auth.uid()) and private.is_member(organisation_id)));
