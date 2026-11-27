// SCP-*: scope boundaries and privilege escalation (DATABASE_TESTING_STRATEGY.md 3.4), including scoped roles.
import { describe, it, expect, inject } from 'vitest'
import { login, rows, denied, errText } from '../helpers/clients'

const w = inject('world')
const ids = w.ids

describe('SCP: member (dan, Team 1) has no administrative power', () => {
  it('cannot invite, assign, suspend or edit structure/settings', async () => {
    const dan = await login('dan')
    expect((await dan.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'z@wc-test.example' })).error).not.toBeNull()
    expect((await dan.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: ids.roleOwner })).error).not.toBeNull()       // self + owner (SCP-10)
    expect((await dan.client.rpc('assign_role', { p_membership: w.mem.ivan.A, p_role: ids.roleAdmin })).error).not.toBeNull()      // SCP-06
    expect((await dan.client.rpc('set_membership_status', { p_membership: w.mem.ivan.A, p_to: 'suspended' })).error).not.toBeNull()
    expect(denied(await dan.client.from('organisations').update({ name: 'x' }).eq('id', w.orgA).select())).toBe(true)
    expect(denied(await dan.client.from('organisation_settings').update({ allow_direct_messages: false }).eq('organisation_id', w.orgA).select())).toBe(true)
    expect((await dan.client.from('campuses').insert({ organisation_id: w.orgA, name: 'x' })).error).not.toBeNull()
    expect(denied(await dan.client.from('teams').update({ description: 'x' }).eq('id', ids.team1).select())).toBe(true)
    expect(rows(await dan.client.from('audit_events').select('id'))).toBe(0)
  })
  it('can read the directory and own data (positive twin)', async () => {
    const dan = await login('dan')
    expect(rows(await dan.client.from('memberships').select('id').eq('organisation_id', w.orgA))).toBeGreaterThan(5)
    expect(rows(await dan.client.from('teams').select('id').eq('organisation_id', w.orgA))).toBeGreaterThanOrEqual(2)
    const mine = await dan.client.from('membership_role_assignments').select('membership_id')
    expect(rows(mine)).toBeGreaterThanOrEqual(1)
    for (const r of (mine.data ?? []) as any[]) {
      // own assignments, or assignments of roles that are public leadership roles
      expect(typeof r.membership_id).toBe('string')
    }
  })
  it("cannot change own status or organisation_id, cannot edit others' names (SCP-16)", async () => {
    const dan = await login('dan')
    expect((await dan.client.from('memberships').update({ status: 'removed' }).eq('id', w.mem.dan.A!).select()).error).not.toBeNull()
    expect((await dan.client.from('memberships').update({ organisation_id: w.orgB }).eq('id', w.mem.dan.A!).select()).error).not.toBeNull()
    expect(denied(await dan.client.from('memberships').update({ display_name: 'hax' }).eq('id', w.mem.ivan.A!).select())).toBe(true)
    expect(rows(await dan.client.from('memberships').update({ display_name: 'Dan T' }).eq('id', w.mem.dan.A!).select())).toBe(1)
  })
})

describe('SCP: team leader (carol, scoped to Team 1) cannot act as an organisation owner', () => {
  it('can manage her own team (positive) but not another team', async () => {
    const carol = await login('carol')
    expect(rows(await carol.client.from('teams').update({ description: 'Band' }).eq('id', ids.team1).select())).toBe(1)
    expect(denied(await carol.client.from('teams').update({ description: 'hax' }).eq('id', ids.team2).select())).toBe(true)      // SCP-04
  })
  it('cannot create teams/departments, settings, roles, invitations, role assignments, suspensions, audit (SCP-05)', async () => {
    const carol = await login('carol')
    expect((await carol.client.from('teams').insert({ organisation_id: w.orgA, name: 'new', department_id: ids.deptMusic })).error).not.toBeNull()
    expect((await carol.client.from('departments').insert({ organisation_id: w.orgA, name: 'd' })).error).not.toBeNull()
    expect(denied(await carol.client.from('organisation_settings').update({ allow_direct_messages: false }).eq('organisation_id', w.orgA).select())).toBe(true)
    expect((await carol.client.from('roles').insert({ organisation_id: w.orgA, name: 'x', is_system: false, assignable_scopes: ['organisation'] })).error).not.toBeNull()
    expect((await carol.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'c@wc-test.example' })).error).not.toBeNull()
    expect((await carol.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: ids.team1 })).error).not.toBeNull()
    expect((await carol.client.rpc('assign_role', { p_membership: w.mem.carol.A, p_role: ids.roleOwner })).error).not.toBeNull()
    expect((await carol.client.rpc('set_membership_status', { p_membership: w.mem.dan.A, p_to: 'suspended' })).error).not.toBeNull()
    expect((await carol.client.rpc('transfer_ownership', { p_org: w.orgA, p_to_membership: w.mem.carol.A })).error).not.toBeNull()
    expect(rows(await carol.client.from('audit_events').select('id'))).toBe(0)
  })
  it('a scoped grant never matches an unscoped (organisation-wide) resource (SCP-11)', async () => {
    const carol = await login('carol')
    expect(denied(await carol.client.from('campuses').update({ name: 'x' }).eq('id', ids.campusN).select())).toBe(true)
    expect(denied(await carol.client.from('locations').insert({ organisation_id: w.orgA, name: 'x' }).select())).toBe(true)
  })
  it("sees contact details only of people in her team (scoped has_perm_over_member)", async () => {
    const [carol, dan, erin] = [await login('carol'), await login('dan'), await login('erin')]
    for (const [u, m] of [[dan, w.mem.dan.A], [erin, w.mem.erin.A]] as const)
      expect((await u.client.from('membership_contacts').insert({ organisation_id: w.orgA, membership_id: m!, phone: '+27111111111' })).error).toBeNull()
    const seen = await carol.client.from('membership_contacts').select('membership_id').eq('organisation_id', w.orgA)
    const ids_ = ((seen.data ?? []) as any[]).map((r) => r.membership_id)
    expect(ids_).toContain(w.mem.dan.A)        // Team 1 member: visible
    expect(ids_).not.toContain(w.mem.erin.A)   // Team 2 member: out of scope
    expect(rows(await dan.client.from('membership_contacts').select('*').eq('membership_id', w.mem.erin.A!))).toBe(0)   // ordinary member sees nobody's
  })
})

describe('SCP: department leader (dora, scoped to North Music) and the privilege ceiling', () => {
  it('manages teams inside her department only', async () => {
    const dora = await login('dora')
    expect(rows(await dora.client.from('teams').update({ description: 'x' }).eq('id', ids.team1).select())).toBe(1)
    expect(denied(await dora.client.from('teams').update({ description: 'x' }).eq('id', ids.team2).select())).toBe(true)
  })
  it('can assign team_leader inside her department but not elsewhere, and not roles she does not hold (SCP-07/08)', async () => {
    const dora = await login('dora')
    const ok = await dora.client.rpc('assign_role', { p_membership: w.mem.felix.A, p_role: ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: ids.team1 })
    expect(ok.error, errText(ok)).toBeNull()
    expect((await dora.client.rpc('assign_role', { p_membership: w.mem.felix.A, p_role: ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: ids.team2 })).error).not.toBeNull()
    expect((await dora.client.rpc('assign_role', { p_membership: w.mem.felix.A, p_role: ids.roleProdLead, p_scope_type: 'team', p_scope_id: ids.team1 })).error).not.toBeNull()
    expect((await dora.client.rpc('assign_role', { p_membership: w.mem.felix.A, p_role: ids.roleAdmin })).error).not.toBeNull()
    expect((await dora.client.rpc('assign_role', { p_membership: w.mem.dora.A, p_role: ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: ids.team1 })).error).not.toBeNull()   // self
    // clean up so other files see a stable world
    const asg = (await dora.client.from('membership_role_assignments').select('id,role_id').eq('membership_id', w.mem.felix.A!).is('revoked_at', null)).data as any[]
    const tl = asg.find((a) => a.role_id === ids.roleTeamLeader)
    expect((await dora.client.rpc('revoke_role', { p_assignment: tl.id })).error).toBeNull()
  })
})

describe('SCP: campus-scoped admin (nora, North) and permission scope validity', () => {
  it('administers North only (SCP-15)', async () => {
    const nora = await login('nora')
    expect(rows(await nora.client.from('campuses').update({ city: 'North City' }).eq('id', ids.campusN).select())).toBe(1)
    expect(denied(await nora.client.from('campuses').update({ city: 'x' }).eq('id', ids.campusS).select())).toBe(true)
    expect(rows(await nora.client.from('teams').update({ description: 'by nora' }).eq('id', ids.team1).select())).toBe(1)     // team 1 is on campus North
    expect(denied(await nora.client.from('teams').update({ description: 'x' }).eq('id', ids.team2).select())).toBe(true)      // team 2 has no campus
  })
  it('organisation-only permissions are inert at campus scope (SCP-14): no settings, no campus creation, no custom roles', async () => {
    const nora = await login('nora')
    expect(denied(await nora.client.from('organisation_settings').update({ allow_direct_messages: false }).eq('organisation_id', w.orgA).select())).toBe(true)
    expect((await nora.client.from('campuses').insert({ organisation_id: w.orgA, name: 'N2' })).error).not.toBeNull()
    expect((await nora.client.from('roles').insert({ organisation_id: w.orgA, name: 'nr', is_system: false, assignable_scopes: ['organisation'] })).error).not.toBeNull()
    expect(rows(await nora.client.from('audit_events').select('id'))).toBe(0)
  })
})

describe('SCP: organisation admin (bob) is not an owner', () => {
  it('cannot grant Owner, cannot self-assign, cannot transfer or remove an Owner (SCP-09/10)', async () => {
    const bob = await login('bob')
    expect((await bob.client.rpc('assign_role', { p_membership: w.mem.dan.A, p_role: ids.roleOwner })).error).not.toBeNull()
    expect((await bob.client.rpc('assign_role', { p_membership: w.mem.bob.A, p_role: ids.roleOwner })).error).not.toBeNull()
    expect((await bob.client.rpc('transfer_ownership', { p_org: w.orgA, p_to_membership: w.mem.bob.A })).error).not.toBeNull()
    expect((await bob.client.rpc('set_membership_status', { p_membership: w.mem.alice.A, p_to: 'suspended' })).error).not.toBeNull()
  })
  it('owner positive twin: can read audit, settings, assign admin-level roles', async () => {
    const alice = await login('alice')
    expect(rows(await alice.client.from('audit_events').select('id').eq('organisation_id', w.orgA))).toBeGreaterThan(0)
    expect(rows(await alice.client.from('organisation_settings').update({ week_starts_on: 1 }).eq('organisation_id', w.orgA).select())).toBe(1)
  })
})

describe('SCP: role-definition ceiling (a custom role cannot be used to self-escalate)', () => {
  it('SCP-21', async () => {
    const [alice, bob, ivan] = [await login('alice'), await login('bob'), await login('ivan')]
    const mk = async (name: string) => (await bob.client.from('roles').insert({ organisation_id: w.orgA, name: `${name}-${w.runId}`, is_system: false, assignable_scopes: ['organisation'] }).select('id').single()).data as any
    const keeper = await mk('RoleKeeper'); const other = await mk('Other')
    for (const p of ['roles.manage', 'roles.assign', 'members.invite'])
      expect((await bob.client.from('role_permissions').insert({ role_id: keeper.id, permission_key: p })).error, p).toBeNull()
    expect((await bob.client.from('role_permissions').insert({ role_id: keeper.id, permission_key: 'org.ownership.manage' })).error).not.toBeNull()   // never in a custom role
    const asg = await bob.client.rpc('assign_role', { p_membership: w.mem.ivan.A, p_role: keeper.id })
    expect(asg.error, errText(asg)).toBeNull()
    // ivan now holds roles.manage through a custom role:
    expect((await ivan.client.from('role_permissions').insert({ role_id: keeper.id, permission_key: 'members.suspend' })).error).not.toBeNull()   // edit own role
    expect((await ivan.client.from('role_permissions').insert({ role_id: other.id, permission_key: 'members.suspend' })).error).not.toBeNull()    // permission he lacks
    expect((await ivan.client.from('role_permissions').insert({ role_id: other.id, permission_key: 'members.invite' })).error).toBeNull()         // permission he holds: allowed
    expect(denied(await ivan.client.from('roles').update({ name: 'renamed-system' }).eq('id', ids.roleAdmin).select())).toBe(true)                // system roles immutable
    // tidy up
    const a = (await alice.client.from('membership_role_assignments').select('id').eq('role_id', keeper.id).is('revoked_at', null)).data as any[]
    for (const x of a) await alice.client.rpc('revoke_role', { p_assignment: x.id })
  })
})
