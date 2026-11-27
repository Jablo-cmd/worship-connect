import type { TestProject } from 'vitest/node'
import { login, rows } from './helpers/clients'
import type { World } from './helpers/world'

/** Builds two churches and every membership state through the REAL API (real JWTs). Runs once per test run.
 *  Requires a clean tenant state: run scripts/reset-test-data.sql first on a persistent dev database. */
export default async function setup(project: TestProject) {
  const must = <T>(r: { data: T; error: { message: string } | null }, what: string): T => {
    if (r.error) throw new Error(`setup ${what}: ${r.error.message}`); return r.data
  }
  const runId = Math.random().toString(36).slice(2, 8)
  const U: Record<string, Awaited<ReturnType<typeof login>>> = {}
  for (const n of ['alice','bob','carol','dan','dora','erin','felix','grace','heidi','ivan','judy','nora']) U[n] = await login(n)
  const existing = await U.alice.client.from('organisations').select('id')
  if (rows(existing) > 0) throw new Error('Tenant data already present. Run scripts/reset-test-data.sql on this database first.')

  const orgA = must(await U.alice.client.rpc('create_organisation', { p_name: 'Church A', p_slug: `wc-a-${runId}`, p_timezone: 'Africa/Johannesburg', p_country_code: 'ZA' }), 'orgA') as string
  const orgB = must(await U.judy.client.rpc('create_organisation', { p_name: 'Church B', p_slug: `wc-b-${runId}`, p_timezone: 'Europe/London', p_country_code: 'GB' }), 'orgB') as string

  const roles = must(await U.alice.client.from('roles').select('id,system_key'), 'roles') as { id: string; system_key: string }[]
  const role = (k: string) => roles.find((r) => r.system_key === k)!.id

  const ins = async (table: string, row: object) => (must(await U.alice.client.from(table).insert({ organisation_id: orgA, ...row }).select('id').single(), table) as { id: string }).id
  const campusN = await ins('campuses', { name: 'A-North' })
  const campusS = await ins('campuses', { name: 'A-South' })
  const ministryW = await ins('ministries', { name: 'North Worship', campus_id: campusN })
  const deptMusic = await ins('departments', { name: 'North Music', ministry_id: ministryW })
  const deptMedia = await ins('departments', { name: 'Media' })
  const team1 = await ins('teams', { name: 'Worship Band', department_id: deptMusic, category: 'band' })
  const team2 = await ins('teams', { name: 'Sound', department_id: deptMedia, category: 'sound' })

  type Inv = { who: string; role?: string; scopeType?: string; scopeId?: string; teams?: string[] }
  const invite = async (inviter: string, org: string, i: Inv) => {
    const r = must(await U[inviter].client.rpc('create_invitation', { p_org: org, p_email: `${i.who}@wc-test.example`, p_role: i.role ?? null,
      p_scope_type: i.scopeType ?? 'organisation', p_scope_id: i.scopeId ?? null, p_team_ids: i.teams ?? [] }), `invite ${i.who}`) as { token: string }[]
    return r[0].token
  }
  const accept = async (who: string, token: string) => must(await U[who].client.rpc('accept_invitation', { p_token: token }), `accept ${who}`)
  const plan: Inv[] = [
    { who: 'bob', role: role('admin') },
    { who: 'carol', role: role('team_leader'), scopeType: 'team', scopeId: team1, teams: [team1] },
    { who: 'dora', role: role('department_leader'), scopeType: 'department', scopeId: deptMusic },
    { who: 'dan', teams: [team1] },
    { who: 'erin', role: role('production_lead'), scopeType: 'team', scopeId: team2, teams: [team2] },
    { who: 'felix', teams: [team1] },
    { who: 'grace' },
    { who: 'ivan' },
    { who: 'nora', role: role('admin'), scopeType: 'campus', scopeId: campusN },
  ]
  for (const p of plan) await accept(p.who, await invite('alice', orgA, p))
  const heidi = await invite('alice', orgA, { who: 'heidi' })                         // pending: deliberately NOT accepted
  await accept('ivan', await invite('judy', orgB, { who: 'ivan', role: role('admin') }))

  const mem: World['mem'] = {}
  for (const n of ['alice','bob','carol','dan','dora','erin','felix','grace','ivan','judy','nora']) {
    const r = must(await U[n].client.from('memberships').select('id,organisation_id').eq('user_id', U[n].uid), `mem ${n}`) as { id: string; organisation_id: string }[]
    mem[n] = {}; for (const x of r) { if (x.organisation_id === orgA) mem[n].A = x.id; if (x.organisation_id === orgB) mem[n].B = x.id }
  }
  must(await U.alice.client.rpc('set_membership_status', { p_membership: mem.grace.A, p_to: 'removed', p_reason: 'fixture' }), 'remove grace')

  const world: World = { runId, orgA, orgB, mem,
    ids: { campusN, campusS, ministryW, deptMusic, deptMedia, team1, team2, roleMember: role('member'), roleAdmin: role('admin'), roleOwner: role('owner'),
           roleTeamLeader: role('team_leader'), roleDeptLeader: role('department_leader'), roleProdLead: role('production_lead'), roleWorshipDirector: role('worship_director') },
    tokens: { heidi } }
  project.provide('world', world)
}
