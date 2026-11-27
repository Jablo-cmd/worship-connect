// ISO-*: Organisation A cannot access Organisation B's data (DATABASE_TESTING_STRATEGY.md 3.2).
// Every denial has a positive twin so a passing test cannot mean "nothing works".
import { describe, it, expect, inject } from 'vitest'
import { login, anon, rows, denied, errText } from '../helpers/clients'

const w = inject('world')

const TABLES: { t: string; col: string; positive: boolean }[] = [
  { t: 'organisations', col: 'id', positive: true }, { t: 'organisation_settings', col: 'organisation_id', positive: true },
  { t: 'memberships', col: 'organisation_id', positive: true }, { t: 'campuses', col: 'organisation_id', positive: true },
  { t: 'ministries', col: 'organisation_id', positive: true }, { t: 'departments', col: 'organisation_id', positive: true },
  { t: 'teams', col: 'organisation_id', positive: true }, { t: 'team_memberships', col: 'organisation_id', positive: true },
  { t: 'membership_role_assignments', col: 'organisation_id', positive: true }, { t: 'membership_status_events', col: 'organisation_id', positive: true },
  { t: 'invitations', col: 'organisation_id', positive: true }, { t: 'audit_events', col: 'organisation_id', positive: true },
  { t: 'files', col: 'organisation_id', positive: false }, { t: 'membership_contacts', col: 'organisation_id', positive: false },
  { t: 'policy_acceptances', col: 'organisation_id', positive: false }, { t: 'locations', col: 'organisation_id', positive: false },
]

describe('ISO: reads', () => {
  for (const { t, col, positive } of TABLES) {
    it(`B owner reads 0 ${t} rows of A; unfiltered read contains no A rows`, async () => {
      const judy = await login('judy')
      const filtered = await judy.client.from(t).select('*').eq(col, w.orgA)
      expect(filtered.error).toBeNull(); expect(rows(filtered)).toBe(0)
      const all = await judy.client.from(t).select('*')
      expect(all.error).toBeNull()
      for (const r of (all.data ?? []) as any[]) expect((t === 'organisations' ? r.id : r.organisation_id)).toBe(w.orgB)
    })
    if (positive) it(`positive twin: A owner reads A ${t} rows`, async () => {
      const alice = await login('alice')
      const r = await alice.client.from(t).select('*').eq(col, w.orgA)
      expect(r.error).toBeNull(); expect(rows(r)).toBeGreaterThan(0)
    })
  }
  it('B owner cannot read A even by guessing exact ids (ISO-15)', async () => {
    const [alice, judy] = [await login('alice'), await login('judy')]
    const camp = await alice.client.from('campuses').select('id').eq('organisation_id', w.orgA).limit(1).single()
    expect(rows(await judy.client.from('campuses').select('*').eq('id', (camp.data as any).id))).toBe(0)
  })
  it('outsider with no memberships sees nothing (ISO-09)', async () => {
    const m = await login('mallory')
    for (const t of ['organisations', 'memberships', 'campuses', 'teams', 'invitations', 'files', 'audit_events', 'membership_role_assignments'])
      expect(rows(await m.client.from(t).select('*')), t).toBe(0)
    expect(rows(await m.client.rpc('my_workspaces'))).toBe(0)
  })
  it('profiles are private: owner sees only her own profile (MUL-09)', async () => {
    const alice = await login('alice')
    const r = await alice.client.from('profiles').select('id'); expect(rows(r)).toBe(1)
  })
})

describe('ISO: writes', () => {
  it('B owner cannot insert into A (ISO-03)', async () => {
    const judy = await login('judy')
    expect((await judy.client.from('campuses').insert({ organisation_id: w.orgA, name: 'pwn' })).error).not.toBeNull()
  })
  it('B owner cannot update or delete A rows; A row unchanged (ISO-05/07)', async () => {
    const [alice, judy] = [await login('alice'), await login('judy')]
    const upd = await judy.client.from('campuses').update({ name: 'pwned' }).eq('id', w.ids.campusN).select()
    expect(denied(upd)).toBe(true)
    expect((await judy.client.from('campuses').delete().eq('id', w.ids.campusN).select()).error).not.toBeNull()   // no DELETE grant
    const check = await alice.client.from('campuses').select('name').eq('id', w.ids.campusN).single()
    expect((check.data as any).name).toBe('A-North')
  })
  it('cannot move a row between organisations (ISO-06): even the OWNER of A cannot re-home her own row', async () => {
    const [alice, judy] = [await login('alice'), await login('judy')]
    const a = await alice.client.from('campuses').update({ organisation_id: w.orgB }).eq('id', w.ids.campusN).select()
    expect(denied(a)).toBe(true)
    const j = await judy.client.from('campuses').update({ organisation_id: w.orgA }).eq('id', w.ids.campusN).select()
    expect(denied(j)).toBe(true)
  })
  it('cross-tenant foreign key is rejected by the schema even when RLS allows the insert (ISO-04)', async () => {
    const judy = await login('judy')
    const r = await judy.client.from('teams').insert({ organisation_id: w.orgB, name: 'forged', department_id: w.ids.deptMusic })
    expect(r.error).not.toBeNull()       // department belongs to A: composite FK / ancestor trigger reject
  })
  it('B owner cannot call any privileged RPC against A (ISO-11)', async () => {
    const [alice, judy] = [await login('alice'), await login('judy')]
    const ra = (await alice.client.from('membership_role_assignments').select('id').eq('membership_id', w.mem.dan.A!).limit(1).single()).data as any
    const calls: [string, any][] = [
      ['set_membership_status', { p_membership: w.mem.dan.A, p_to: 'suspended' }],
      ['assign_role', { p_membership: w.mem.dan.A, p_role: w.ids.roleOwner }],
      ['revoke_role', { p_assignment: ra.id }],
      ['create_invitation', { p_org: w.orgA, p_email: 'x@wc-test.example' }],
      ['register_file', { p_org: w.orgA, p_filename: 'x.pdf', p_mime: 'application/pdf', p_size: 1, p_purpose: 'other' }],
      ['leave_organisation', { p_org: w.orgA }],
      ['transfer_ownership', { p_org: w.orgA, p_to_membership: w.mem.judy.B }],
      ['grant_support_access', { p_org: w.orgA, p_platform_user: w.mem.judy.B, p_level: 'metadata', p_reason: 'abcde' }],
    ]
    for (const [fn, args] of calls) { const r = await judy.client.rpc(fn, args); expect(r.error, fn).not.toBeNull() }
    expect(rows(await alice.client.from('membership_role_assignments').select('id').eq('id', ra.id).is('revoked_at', null))).toBe(1)
  })
})

describe('ISO: anonymous and API surface', () => {
  it('anon has no table privileges (ISO-10)', async () => {
    const a = anon()
    for (const t of ['organisations', 'memberships', 'campuses', 'roles', 'permissions', 'files', 'audit_events', 'invitations']) {
      const r = await a.from(t).select('*'); expect(r.error, t).not.toBeNull()
    }
  })
  it('anon cannot call RPCs', async () => {
    const a = anon()
    for (const [fn, args] of [['create_organisation', { p_name: 'x', p_slug: 'x-slug', p_timezone: 'UTC' }], ['accept_invitation', { p_token: 'x' }], ['my_workspaces', {}]] as const)
      expect((await a.rpc(fn, args as any)).error, fn).not.toBeNull()
  })
  it('private and platform schemas are not reachable through the API', async () => {
    const alice = await login('alice')
    expect((await alice.client.schema('platform' as any).from('admins').select('*')).error).not.toBeNull()
    expect((await alice.client.schema('private' as any).rpc('is_member', { p_org: w.orgA })).error).not.toBeNull()
    expect((await alice.client.rpc('has_perm', { p_org: w.orgA, p_perm: 'music.view' })).error).not.toBeNull()   // not in public
    expect((await alice.client.rpc('write_audit', {})).error).not.toBeNull()
  })
  it('invitation tokens table is unreachable by everyone, including the Owner (CAT-16)', async () => {
    const alice = await login('alice')
    const r = await alice.client.from('invitation_tokens').select('*'); expect(r.error).not.toBeNull()
  })
  it('error responses do not reveal whether a foreign row exists (ISO-15)', async () => {
    const judy = await login('judy')
    const real = await judy.client.rpc('set_membership_status', { p_membership: w.mem.dan.A, p_to: 'suspended' })
    const fake = await judy.client.rpc('set_membership_status', { p_membership: '00000000-0000-4000-8000-00000000dead', p_to: 'suspended' })
    expect(errText(real)).toBe(errText(fake))
  })
})
