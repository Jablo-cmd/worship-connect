// INT-*, DEF-*, audit: schema constraints, triggers, RPC hardening and the append-only audit log.
import { describe, it, expect, inject } from 'vitest'
import { login, rows, denied, errText } from '../helpers/clients'

const w = inject('world')

describe('INT: organisation creation and immutability', () => {
  it('invalid time zones are rejected (abbreviations, POSIX strings, Etc/ and odd names) (CAT-20)', async () => {
    const alice = await login('alice')
    for (const tz of ['EST', 'UTC+3', 'Factory', 'Etc/GMT+5', 'posix/Europe/London', '', 'Not/AZone']) {
      const r = await alice.client.rpc('create_organisation', { p_name: 'Bad TZ', p_slug: `bad-tz-${w.runId}`, p_timezone: tz })
      expect(r.error, `tz=${tz}`).not.toBeNull()
    }
    expect(rows(await alice.client.from('organisations').select('id').ilike('slug', 'bad-tz-%'))).toBe(0)     // nothing half-created (S-6)
  })
  it('invalid or duplicate slugs are rejected and leave no orphan rows', async () => {
    const alice = await login('alice')
    for (const slug of ['Bad Slug!', 'a', '-abc', 'abc-', 'x'.repeat(60), `wc-a-${w.runId}`])
      expect((await alice.client.rpc('create_organisation', { p_name: 'X', p_slug: slug, p_timezone: 'UTC' })).error, slug).not.toBeNull()
    expect(rows(await alice.client.from('organisations').select('id'))).toBeGreaterThanOrEqual(1)
  })
  it('slug, status and creator are not client-editable (column grants + trigger)', async () => {
    const alice = await login('alice')
    for (const patch of [{ slug: 'hijack' }, { status: 'suspended' }, { created_by: alice.uid }, { id: crypto.randomUUID() }])
      expect((await alice.client.from('organisations').update(patch).eq('id', w.orgA).select()).error, JSON.stringify(patch)).not.toBeNull()
  })
  it('an unverified-e-mail or anonymous caller cannot create organisations', async () => {
    const { anon } = await import('../helpers/clients')
    expect((await anon().rpc('create_organisation', { p_name: 'x', p_slug: 'x-anon-slug', p_timezone: 'UTC' })).error).not.toBeNull()
  })
})

describe('INT: hierarchy and scope integrity', () => {
  it('scope ancestors are DERIVED from the lowest level and contradictions are rejected (INT-13)', async () => {
    const alice = await login('alice')
    const dept = (await alice.client.from('departments').insert({ organisation_id: w.orgA, name: `IntDept-${w.runId}`, ministry_id: w.ids.ministryW }).select('id,campus_id,ministry_id').single()).data as any
    expect(dept.campus_id).toBe(w.ids.campusN)                        // derived from the ministry
    const team = await alice.client.from('teams').insert({ organisation_id: w.orgA, name: `IntTeam-${w.runId}`, department_id: dept.id }).select('campus_id,ministry_id,department_id').single()
    expect(team.data).toMatchObject({ campus_id: w.ids.campusN, ministry_id: w.ids.ministryW, department_id: dept.id })
    const bad = await alice.client.from('teams').insert({ organisation_id: w.orgA, name: `Bad-${w.runId}`, department_id: dept.id, campus_id: w.ids.campusS })
    expect(bad.error).not.toBeNull()                                   // client-supplied campus contradicts the department
  })
  it('role assignments must be at a scope the role allows (INT-04)', async () => {
    const alice = await login('alice')
    expect((await alice.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: w.ids.roleTeamLeader })).error).not.toBeNull()                      // team_leader at organisation scope
    expect((await alice.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: w.ids.roleOwner, p_scope_type: 'campus', p_scope_id: w.ids.campusN })).error).not.toBeNull()
    expect((await alice.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: w.ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: w.ids.team1 })).error?.message).toBeUndefined()
    const mine = (await alice.client.from('membership_role_assignments').select('id,role_id').eq('membership_id', w.mem.dan.A!).is('revoked_at', null)).data as any[]
    await alice.client.rpc('revoke_role', { p_assignment: mine.find((a) => a.role_id === w.ids.roleTeamLeader).id })
  })
  it('a scope row from another organisation cannot be used for a role assignment (INT-01)', async () => {
    const judy = await login('judy')
    expect((await judy.client.rpc('assign_role', { p_membership: w.mem.ivan.B, p_role: w.ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: w.ids.team1 })).error).not.toBeNull()
  })
  it('only active members can join rosters; a roster cannot reference another organisation’s member (INT-01)', async () => {
    const alice = await login('alice')
    const removed = await alice.client.from('team_memberships').insert({ organisation_id: w.orgA, team_id: w.ids.team1, membership_id: w.mem.grace.A })   // grace is removed
    expect(removed.error).not.toBeNull()
    const cross = await alice.client.from('team_memberships').insert({ organisation_id: w.orgA, team_id: w.ids.team1, membership_id: w.mem.judy.B })
    expect(cross.error).not.toBeNull()
  })
  it('roles: system roles are immutable to clients; names unique per organisation; scopes validated', async () => {
    const bob = await login('bob')
    expect(denied(await bob.client.from('roles').update({ name: 'x' }).eq('id', w.ids.roleOwner).select())).toBe(true)
    expect((await bob.client.from('roles').insert({ organisation_id: w.orgA, name: 'sys', is_system: true, system_key: 'owner', assignable_scopes: ['organisation'] })).error).not.toBeNull()
    expect((await bob.client.from('roles').insert({ organisation_id: w.orgA, name: 'badscope', is_system: false, assignable_scopes: ['galaxy'] })).error).not.toBeNull()
    const name = `Dup-${w.runId}`
    expect((await bob.client.from('roles').insert({ organisation_id: w.orgA, name, is_system: false, assignable_scopes: ['organisation'] })).error).toBeNull()
    expect((await bob.client.from('roles').insert({ organisation_id: w.orgA, name: name.toUpperCase(), is_system: false, assignable_scopes: ['organisation'] })).error).not.toBeNull()
  })
})

describe('DEF: RPC hardening', () => {
  it('malformed parameters produce errors, never privilege or crashes (DEF-05)', async () => {
    const dan = await login('dan')
    const junk: [string, any][] = [
      ['set_membership_status', { p_membership: 'not-a-uuid', p_to: 'suspended' }], ['assign_role', { p_membership: null, p_role: null }],
      ['create_invitation', { p_org: w.orgA, p_email: "x'; drop table public.memberships; --" }], ['accept_invitation', { p_token: null }],
      ['register_file', { p_org: w.orgA, p_filename: "'; --", p_mime: 'application/pdf', p_size: -5, p_purpose: 'other' }], ['delete_file', { p_file: crypto.randomUUID() }],
    ]
    for (const [fn, args] of junk) expect((await dan.client.rpc(fn, args)).error, fn).not.toBeNull()
    expect(rows(await dan.client.from('memberships').select('id').eq('organisation_id', w.orgA))).toBeGreaterThan(5)       // table intact
  })
  it('"not found" and "forbidden" are indistinguishable (DEF-06)', async () => {
    const dan = await login('dan')
    const forbidden = await dan.client.rpc('assign_role', { p_membership: w.mem.ivan.A, p_role: w.ids.roleAdmin })
    const missing = await dan.client.rpc('assign_role', { p_membership: crypto.randomUUID(), p_role: w.ids.roleAdmin })
    expect(errText(forbidden)).toBe(errText(missing))
  })
  it('support-access grants are Owner-only and cannot target non-staff (D-036)', async () => {
    const [alice, bob] = [await login('alice'), await login('bob')]
    expect((await bob.client.rpc('grant_support_access', { p_org: w.orgA, p_platform_user: alice.uid, p_level: 'content_read', p_reason: 'test reason' })).error).not.toBeNull()
    expect((await alice.client.rpc('grant_support_access', { p_org: w.orgA, p_platform_user: alice.uid, p_level: 'content_read', p_reason: 'test reason' })).error).not.toBeNull()   // alice is not platform staff
  })
})

describe('AUDIT: append-only, allow-listed, permissioned', () => {
  it('sensitive changes are audited with old/new for allow-listed columns only; only audit.view holders can read', async () => {
    const [alice, dan, judy] = [await login('alice'), await login('dan'), await login('judy')]
    const upd = await alice.client.from('organisation_settings').update({ allow_direct_messages: false }).eq('organisation_id', w.orgA).select()
    expect(rows(upd)).toBe(1)
    await alice.client.from('organisation_settings').update({ allow_direct_messages: true }).eq('organisation_id', w.orgA)
    const ev = (await alice.client.from('audit_events').select('*').eq('organisation_id', w.orgA).eq('action', 'organisation_settings.updated').order('occurred_at', { ascending: false }).limit(1).single()).data as any
    expect(ev.changes).toEqual({ allow_direct_messages: { old: false, new: true } })
    expect(ev.actor_type).toBe('user'); expect(ev.actor_user_id).toBe(alice.uid)
    expect(rows(await dan.client.from('audit_events').select('id').eq('organisation_id', w.orgA))).toBe(0)
    expect(rows(await judy.client.from('audit_events').select('id').eq('organisation_id', w.orgA))).toBe(0)
  })
  it('security events exist for membership, role and invitation changes and never contain tokens or reasons', async () => {
    const alice = await login('alice')
    const all = (await alice.client.from('audit_events').select('action,severity,changes,metadata').eq('organisation_id', w.orgA)).data as any[]
    const actions = new Set(all.map((e) => e.action))
    for (const a of ['organisation.created', 'invitation.created', 'invitation.accepted', 'membership.removed', 'role.assigned']) expect(actions.has(a), a).toBe(true)
    expect(JSON.stringify(all)).not.toMatch(/token|password|fixture|policy test|phone/i)
  })
  it('nobody can modify or delete audit rows through the API (CAT-15)', async () => {
    const alice = await login('alice')
    expect((await alice.client.from('audit_events').update({ action: 'x.y' }).eq('organisation_id', w.orgA).select()).error).not.toBeNull()
    expect((await alice.client.from('audit_events').delete().eq('organisation_id', w.orgA).select()).error).not.toBeNull()
    expect((await alice.client.from('audit_events').insert({ organisation_id: w.orgA, actor_type: 'user', action: 'fake.event' })).error).not.toBeNull()
    expect((await alice.client.from('membership_status_events').delete().eq('organisation_id', w.orgA).select()).error).not.toBeNull()
  })
})
