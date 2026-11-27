// INV-*: invitation security (DATABASE_TESTING_STRATEGY.md 3.5). All heidi/grace invitation state lives in this file.
import { describe, it, expect, inject } from 'vitest'
import { login, rows, errText } from '../helpers/clients'

const w = inject('world')
const TABLES = ['organisations', 'memberships', 'campuses', 'teams', 'invitations', 'membership_role_assignments', 'files', 'audit_events', 'team_memberships']

describe('INV: a pending invitee has no access before accepting', () => {
  it('sees nothing in the organisation (INV-01/03)', async () => {
    const heidi = await login('heidi')
    for (const t of TABLES) expect(rows(await heidi.client.from(t).select('*')), t).toBe(0)
    expect(rows(await heidi.client.rpc('my_workspaces'))).toBe(0)
    expect((await heidi.client.from('invitation_tokens').select('*')).error).not.toBeNull()
  })
  it('cannot act on the organisation through any RPC (INV-01)', async () => {
    const heidi = await login('heidi')
    for (const [fn, args] of [['create_invitation', { p_org: w.orgA, p_email: 'q@wc-test.example' }],
      ['register_file', { p_org: w.orgA, p_filename: 'x.pdf', p_mime: 'application/pdf', p_size: 1, p_purpose: 'other' }],
      ['leave_organisation', { p_org: w.orgA }]] as const)
      expect((await heidi.client.rpc(fn, args as any)).error, fn).not.toBeNull()
  })
  it('wrong token, another user’s token and a malformed token fail with the SAME generic error (INV-05/06)', async () => {
    const [heidi, mallory] = [await login('heidi'), await login('mallory')]
    const e = [errText(await heidi.client.rpc('accept_invitation', { p_token: 'deadbeef' })),
               errText(await mallory.client.rpc('accept_invitation', { p_token: w.tokens.heidi })),     // valid token, wrong user
               errText(await heidi.client.rpc('accept_invitation', { p_token: 'x'.repeat(500) })),
               errText(await heidi.client.rpc('get_invitation_preview', { p_token: 'deadbeef' }))]
    expect(new Set(e).size).toBe(1); expect(e[0]).toBe('invalid_invitation')
    expect(rows(await heidi.client.from('memberships').select('id'))).toBe(0)
  })
  it('the preview exposes only organisation name, inviter and expiry (INV-02)', async () => {
    const heidi = await login('heidi')
    const p = await heidi.client.rpc('get_invitation_preview', { p_token: w.tokens.heidi })
    expect(p.error).toBeNull()
    const row = (p.data as any[])[0]
    expect(Object.keys(row).sort()).toEqual(['expires_at', 'inviter_display_name', 'organisation_name'])
    expect(row.organisation_name).toBe('Church A')
  })
  it('an invitee cannot use another invitee’s e-mail-bound token even if leaked (e-mail binding)', async () => {
    const dan = await login('dan')     // active member, different e-mail
    expect(errText(await dan.client.rpc('accept_invitation', { p_token: w.tokens.heidi }))).toBe('invalid_invitation')
  })
})

describe('INV: creation is constrained by the inviter’s scope and ceiling (INV-09)', () => {
  it('a member cannot invite; a team leader cannot invite; nobody can invite with a role above their ceiling', async () => {
    const [dan, carol, dora] = [await login('dan'), await login('carol'), await login('dora')]
    expect((await dan.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n1@wc-test.example' })).error).not.toBeNull()
    expect((await carol.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n2@wc-test.example' })).error).not.toBeNull()
    expect((await dora.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n3@wc-test.example', p_role: w.ids.roleAdmin })).error).not.toBeNull()
    expect((await dora.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n4@wc-test.example' })).error).not.toBeNull()   // org-scope invite needs org-scope grant
    const ok = await dora.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n5@wc-test.example', p_role: w.ids.roleTeamLeader, p_scope_type: 'team', p_scope_id: w.ids.team1, p_team_ids: [w.ids.team1] })
    expect(ok.error, errText(ok)).toBeNull()                                                                                         // inside her department
    expect((await dora.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'n6@wc-test.example', p_team_ids: [w.ids.team2] })).error).not.toBeNull()   // team outside scope
  })
  it('inviting an existing active member is refused; one pending invitation per e-mail', async () => {
    const alice = await login('alice')
    expect(errText(await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'dan@wc-test.example' }))).toBe('already_member')
    const first = await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'pending1@wc-test.example' })
    expect(first.error).toBeNull()
    expect((await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'PENDING1@wc-test.example' })).error).not.toBeNull()   // case-insensitive uniqueness
  })
  it('revoked invitations cannot be accepted; resend invalidates the old token and is throttled (INV-10)', async () => {
    const [alice, mallory] = [await login('alice'), await login('mallory')]
    const mk = async () => ((await alice.client.rpc('create_invitation', { p_org: w.orgA, p_email: 'mallory@wc-test.example' })).data as any[])[0]
    const inv = await mk()
    expect((await alice.client.rpc('revoke_invitation', { p_invitation: inv.invitation_id })).error).toBeNull()
    expect(errText(await mallory.client.rpc('accept_invitation', { p_token: inv.token }))).toBe('invalid_invitation')
    const inv2 = await mk()
    expect(errText(await alice.client.rpc('resend_invitation', { p_invitation: inv2.invitation_id }))).toBe('throttled')     // sent <1 minute ago
    expect((await (await login('dan')).client.rpc('revoke_invitation', { p_invitation: inv2.invitation_id })).error).not.toBeNull()   // non-inviter without permission
    await alice.client.rpc('revoke_invitation', { p_invitation: inv2.invitation_id })
  })
})

describe('INV: acceptance (runs last: it consumes heidi’s invitation)', () => {
  it('the correct token + verified e-mail activates the membership; access appears only now (INV-04)', async () => {
    const heidi = await login('heidi')
    expect(rows(await heidi.client.from('campuses').select('id'))).toBe(0)
    const a = await heidi.client.rpc('accept_invitation', { p_token: w.tokens.heidi })
    expect(a.error, errText(a)).toBeNull()
    expect(rows(await heidi.client.from('campuses').select('id').eq('organisation_id', w.orgA))).toBe(2)
    expect(rows(await heidi.client.rpc('my_workspaces'))).toBe(1)
    const roles = (await heidi.client.from('membership_role_assignments').select('role_id').eq('membership_id', (a.data as string))).data as any[]
    expect(roles.map((r) => r.role_id)).toContain(w.ids.roleMember)                        // baseline `member` role auto-assigned
    expect(rows(await heidi.client.from('audit_events').select('id'))).toBe(0)             // and no admin power
  })
  it('the same token cannot be used twice (INV-08)', async () => {
    const heidi = await login('heidi')
    expect(errText(await heidi.client.rpc('accept_invitation', { p_token: w.tokens.heidi }))).toBe('invalid_invitation')
  })
  it('pre-assigned teams, roles and scopes were applied by the acceptance (carol)', async () => {
    const alice = await login('alice')
    const tm = await alice.client.from('team_memberships').select('team_id').eq('membership_id', w.mem.carol.A!)
    expect((tm.data as any[]).map((r) => r.team_id)).toEqual([w.ids.team1])
    const ra = (await alice.client.from('membership_role_assignments').select('role_id,scope_type,team_id').eq('membership_id', w.mem.carol.A!).is('revoked_at', null)).data as any[]
    expect(ra.find((r) => r.role_id === w.ids.roleTeamLeader)).toMatchObject({ scope_type: 'team', team_id: w.ids.team1 })
  })
})
