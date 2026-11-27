-- M-023: realtime authorisation foundation. Private Broadcast channels, authorised by RLS on realtime.messages, with
-- ID-ONLY payloads (D-035). Postgres Changes is NOT used for tenant content. Topics in Phase 1:
--   org:{org}:me:{membership}   exactly that membership (notifications, membership.revoked)
--   org:{org}:presence          active members of that organisation
-- Later phases extend private.can_read_topic with conv: and service: topics.
set lock_timeout = '10s';
set statement_timeout = '60s';

create or replace function private.can_read_topic(p_topic text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare p text[] := string_to_array(p_topic, ':'); v_org uuid := private.try_uuid(p[2]); v_id uuid := private.try_uuid(p[4]);
begin
  if p[1] is distinct from 'org' or v_org is null or not private.is_member(v_org) then return false; end if;
  return case p[3]
    when 'me'       then v_id is not null and v_id = private.my_membership_id(v_org)
    when 'presence' then p[4] is null
    else false end;
end $$;
grant execute on function private.can_read_topic(text) to authenticated, service_role;

create policy rt_receive on realtime.messages for select to authenticated
  using ( realtime.messages.extension in ('broadcast','presence') and private.can_read_topic((select realtime.topic())) );
-- Clients may only SEND presence on the organisation presence topic; they cannot broadcast onto content topics.
create policy rt_presence_send on realtime.messages for insert to authenticated
  with check ( realtime.messages.extension = 'presence' and (select realtime.topic()) like 'org:%:presence'
               and private.can_read_topic((select realtime.topic())) );
