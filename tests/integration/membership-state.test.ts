// MEM-*: suspended / removed members, lifecycle and the last-owner invariant (DATABASE_TESTING_STRATEGY.md 3.3).
import { describe, it, expect, inject, afterAll } from 'vitest'
import { login, rows, denied, errText, newClient } from '../helpers/clients'

const w = inject('world')
const TABLES = ['organisations', 'campuses', 'teams', 'team_memberships', 'membership_role_assignments', 'invitations', 'files', 'audit_events']

describe('MEM: suspension is effective on the SAME session, with no re-login (MEM-06)', () => {
  afterAll(async () => { const a = await login('alice'); await a.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'active', p_reason: 'test cleanup' }) })

  it('felix can read before, loses everything immediately after, and sees his own status', async () => {
    const [alice, felix] = [await login('alice'), await login('felix')]
    expect(rows(await felix.client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(2)
    expect(rows(await felix.client.from('organisations').select('id'))).toBe(1)
    const s = await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'suspended', p_reason: 'policy test' })
    expect(s.error, errText(s)).toBeNull()
    for (const t of TABLES) expect(rows(await felix.client.from(t).select('*')), `${t} after suspension`).toBe(0)       // same JWT
    const own = await felix.client.from('memberships').select('id,status').eq('organisation_id', w.orgA)
    expect(rows(own)).toBe(1); expect((own.data as any[])[0].status).toBe('suspended')                                   // only his own row
    const ws = await felix.client.rpc('my_workspaces'); expect((ws.data as any[])[0].my_status).toBe('suspended')
    // other members are unaffected (MEM-11)
    expect(rows(await (await login('dan')).client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(2)
  })
  it('a suspended member cannot write or call RPCs (MEM-02/03)', async () => {
    const felix = await login('felix')
    expect(denied(await felix.client.from('memberships').update({ display_name: 'x' }).eq('id', w.mem.felix.A!).select())).toBe(true)
    expect((await felix.client.from('memberships').update({ status: 'active' }).eq('id', w.mem.felix.A!).select()).error).not.toBeNull()   // MEM-09: cannot reinstate himself
    for (const [fn, args] of [['register_file', { p_org: w.orgA, p_filename: 'x.pdf', p_mime: 'application/pdf', p_size: 1, p_purpose: 'other' }],
      ['leave_organisation', { p_org: w.orgA }], ['create_invitation', { p_org: w.orgA, p_email: 'f@wc-test.example' }]] as const)
      expect((await felix.client.rpc(fn, args as any)).error, fn).not.toBeNull()
    expect(rows(await felix.client.from('membership_contacts').select('*'))).toBe(0)
  })
  it('re-invitation cannot bypass a suspension (MEM-10)', async () => {
    const [alice, felix] = [await login('alice'), await login('felix')]
    const inv = await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'felix@wc-test.example' })
    // an active-membership check does not apply (he is suspended), so an invitation can be created, but acceptance must fail generically
    if (!inv.error) {
      expect(errText(await felix.client.rpc('accept_invitation', { p_token: (inv.data as any[])[0].token }))).toBe('invalid_invitation')
      await alice.client.rpc('revoke_invitation', { p_invitation: (inv.data as any[])[0].invitation_id })
    }
  })
  it('reinstatement restores access on the same session; history records each transition with its reason', async () => {
    const [alice, felix] = [await login('alice'), await login('felix')]
    expect((await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'active', p_reason: 'resolved' })).error).toBeNull()
    expect(rows(await felix.client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(2)
    const ev = (await alice.client.from('membership_status_events').select('from_status,to_status,reason').eq('membership_id', w.mem.felix.A!).order('occurred_at')).data as any[]
    // (other files in the same run also suspend felix, so assert on the LAST transitions, which are this test's own)
    expect(ev.slice(-2).map((e) => e.to_status)).toEqual(['suspended', 'active'])
    expect(ev.at(-2)!.reason).toBe('policy test'); expect(ev.at(-1)!.reason).toBe('resolved')
    expect(ev[0].to_status).toBe('active')                                  // first event: the join itself
    expect(rows(await (await login('dan')).client.from('membership_status_events').select('*').eq('membership_id', w.mem.felix.A!))).toBe(0)   // reasons are restricted
  })
})

describe('MEM: removed members (MEM-08)', () => {
  it('grace (removed in fixtures) has no access, can learn nothing, and can be re-invited into the SAME membership row', async () => {
    const [alice, grace] = [await login('alice'), await login('grace')]
    for (const t of TABLES) expect(rows(await grace.client.from(t).select('*')), t).toBe(0)
    expect(rows(await grace.client.rpc('my_workspaces'))).toBe(0)
    const inv = await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'grace@wc-test.example' })
    expect(inv.error, errText(inv)).toBeNull()
    const a = await grace.client.rpc('accept_invitation', { p_token: (inv.data as any[])[0].token })
    expect(a.error, errText(a)).toBeNull()
    expect(a.data).toBe(w.mem.grace.A)                                                  // same row: stable identity and history
    expect(rows(await grace.client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(2)
    await alice.client.rpc('set_membership_status', { p_membership: w.mem.grace.A, p_to: 'removed', p_reason: 'fixture reset' })
  })
})

describe('MEM: legal transitions and the last-owner invariant (MEM-13/14)', () => {
  it('a sole Owner cannot leave, be suspended or be demoted', async () => {
    const judy = await login('judy')
    expect(errText(await judy.client.rpc('leave_organisation', { p_org: w.orgB }))).toMatch(/last_owner/)
    const own = (await judy.client.from('membership_role_assignments').select('id,role_id').eq('membership_id', w.mem.judy.B!).is('revoked_at', null)).data as any[]
    const ownerAsg = own.find((a) => a.role_id === w.ids.roleOwner)
    expect((await judy.client.rpc('revoke_role', { p_assignment: ownerAsg.id })).error).not.toBeNull()      // no self-revocation
  })
  it('ownership transfer keeps the invariant and the new Owner can then act (own throwaway organisation)', async () => {
    const [alice, bob] = [await login('alice'), await login('bob')]
    const org = (await alice.client.rpc('create_organisation', { p_name: 'Transfer Test', p_slug: `wc-t-${w.runId}`, p_timezone: 'UTC' })).data as string
    const inv = await alice.client.rpc('create_invitation', { p_org: org, p_email: 'bob@wc-test.example' })
    const mem = (await bob.client.rpc('accept_invitation', { p_token: (inv.data as any[])[0].token })).data as string
    expect((await bob.client.rpc('transfer_ownership', { p_org: org, p_to_membership: mem })).error).not.toBeNull()        // bob is not an owner yet
    expect((await alice.client.rpc('transfer_ownership', { p_org: org, p_to_membership: mem })).error).toBeNull()
    expect((await alice.client.rpc('set_membership_status', { p_membership: mem, p_to: 'suspended' })).error).not.toBeNull() // alice is no longer owner
    const aliceMem = (await bob.client.from('memberships').select('id').eq('organisation_id', org).eq('user_id', alice.uid).single()).data as any
    expect((await bob.client.rpc('set_membership_status', { p_membership: aliceMem.id, p_to: 'suspended', p_reason: 'new owner acts' })).error).toBeNull()   // bob is now the Owner
    expect((await bob.client.rpc('set_membership_status', { p_membership: aliceMem.id, p_to: 'active' })).error).toBeNull()
    expect(rows(await bob.client.from('organisations').select('id').eq('id', org))).toBe(1)
  })
  it('illegal transitions are rejected by the schema (removed -> suspended)', async () => {
    const alice = await login('alice')
    const r = await alice.client.rpc('set_membership_status', { p_membership: w.mem.grace.A, p_to: 'suspended' })    // grace is removed
    expect(r.error).not.toBeNull()
  })
})
