// MUL-*: one account, several churches (DATABASE_TESTING_STRATEGY.md 3.8). ivan is a Member in A and an Admin in B.
import { describe, it, expect, inject } from 'vitest'
import { login, rows, denied, errText } from '../helpers/clients'

const w = inject('world')

describe('MUL: access is the union of memberships, evaluated per organisation', () => {
  it('an unfiltered read returns exactly the rows of his own organisations (MUL-01)', async () => {
    const ivan = await login('ivan')
    const r = await ivan.client.from('campuses').select('organisation_id')
    const orgs = new Set(((r.data ?? []) as any[]).map((x) => x.organisation_id))
    expect(orgs.has(w.orgA)).toBe(true)
    for (const o of orgs) expect([w.orgA, w.orgB]).toContain(o)
    expect(rows(await ivan.client.from('organisations').select('id'))).toBe(2)
    expect(rows(await ivan.client.rpc('my_workspaces'))).toBe(2)
  })
  it('authority does not bleed between churches (MUL-02/03)', async () => {
    const ivan = await login('ivan')
    // Admin in B: allowed
    const okB = await ivan.client.from('campuses').insert({ organisation_id: w.orgB, name: `B-Campus-${w.runId}` }).select('id')
    expect(okB.error, errText(okB)).toBeNull()
    // Member in A: every administrative action refused
    expect((await ivan.client.from('campuses').insert({ organisation_id: w.orgA, name: 'x' })).error).not.toBeNull()
    expect((await ivan.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'm@wc-test.example' })).error).not.toBeNull()
    expect((await ivan.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: w.ids.roleAdmin })).error).not.toBeNull()
    expect((await ivan.client.rpc('set_membership_status', { p_membership: w.mem.dan.A, p_to: 'suspended' })).error).not.toBeNull()
    expect(rows(await ivan.client.from('audit_events').select('id').eq('organisation_id', w.orgA))).toBe(0)
    expect(rows(await ivan.client.from('audit_events').select('id').eq('organisation_id', w.orgB))).toBeGreaterThan(0)
  })
  it('references cannot cross organisations even for a user with rights in both (MUL-04)', async () => {
    const ivan = await login('ivan')
    // He is Admin in B; a B team may not reference A's department:
    const r = await ivan.client.from('teams').insert({ organisation_id: w.orgB, name: 'cross', department_id: w.ids.deptMusic })
    expect(r.error).not.toBeNull()
  })
  it('suspension in one church does not affect the other (MUL-07/11)', async () => {
    const [alice, ivan] = [await login('alice'), await login('ivan')]
    expect((await alice.client.rpc('set_membership_status', { p_membership: w.mem.ivan.A, p_to: 'suspended', p_reason: 'multi-org test' })).error).toBeNull()
    try {
      expect(rows(await ivan.client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(0)
      expect(rows(await ivan.client.from('campuses').select('id').eq('organisation_id', w.orgB))).toBeGreaterThan(0)
      const ws = (await ivan.client.rpc('my_workspaces')).data as any[]
      expect(ws.find((x) => x.organisation_id === w.orgA).my_status).toBe('suspended')
      expect(ws.find((x) => x.organisation_id === w.orgB).my_status).toBe('active')
    } finally {
      await alice.client.rpc('set_membership_status', { p_membership: w.mem.ivan.A, p_to: 'active', p_reason: 'restore' })
    }
  })
  it('the workspace selector is not an authorisation: filtering by the "wrong" organisation just returns that organisation’s permitted rows (MUL-06)', async () => {
    const [ivan, dan] = [await login('ivan'), await login('dan')]
    const asDanForB = await dan.client.from('campuses').select('id').eq('organisation_id', w.orgB)
    expect(rows(asDanForB)).toBe(0)                                   // dan is not in B: asking for B yields nothing
    const asIvanForA = await ivan.client.from('campuses').select('id').eq('organisation_id', w.orgA)
    expect(rows(asIvanForA)).toBe(2)
  })
  it('DMs/identity do not span organisations: profiles stay private; a user gets separate display names per church (MUL-09)', async () => {
    const ivan = await login('ivan')
    const a = await ivan.client.from('memberships').update({ display_name: 'Ivan (Church A)' }).eq('id', w.mem.ivan.A!).select('display_name')
    expect(rows(a)).toBe(1)
    const b = (await ivan.client.from('memberships').select('display_name').eq('id', w.mem.ivan.B!).single()).data as any
    expect(b.display_name).not.toBe('Ivan (Church A)')
    expect(rows(await ivan.client.from('profiles').select('id'))).toBe(1)
    expect(denied(await (await login('judy')).client.from('profiles').select('*').eq('id', ivan.uid))).toBe(true)
  })
})
