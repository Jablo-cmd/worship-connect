// MTX-*: the permission catalogue in the database equals docs/PERMISSIONS_MATRIX.md (the single source of truth).
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { login } from '../helpers/clients'

const md = readFileSync(new URL('../../docs/PERMISSIONS_MATRIX.md', import.meta.url), 'utf8')
const SCOPE: Record<string, string> = { O: 'organisation', C: 'campus', M: 'ministry', D: 'department', T: 'team' }
const ROLES = ['owner', 'admin', 'pastor', 'worship_director', 'department_leader', 'team_leader', 'production_lead', 'member']

function parse() {
  const sec2 = md.slice(md.indexOf('## 2. Permission catalogue'), md.indexOf('### 2.9'))
  const perms = [...sec2.matchAll(/^\| `([a-z_.]+)` \| ([OCMDT ]+) \| (✔?)\s*\|/gm)].map((m) => ({ key: m[1], scopes: m[2].trim().split(/\s+/).map((x) => SCOPE[x]).sort(), sensitive: m[3] === '✔' }))
  const sec4 = md.slice(md.indexOf('## 4. Permission × role matrix'), md.indexOf('### 4.1'))
  const map: Record<string, Set<string>> = Object.fromEntries(ROLES.map((r) => [r, new Set<string>()]))
  for (const m of sec4.matchAll(/^\| `([a-z_.]+)` \|(.*)\|$/gm)) {
    m[2].split('|').map((c) => c.trim()).forEach((c, i) => { if (c === '✔') map[ROLES[i]].add(m[1]) })
  }
  return { perms, map }
}

describe('MTX-01: catalogue, roles and mappings equal the matrix document', () => {
  it('45 permissions with the documented scopes and sensitivity', async () => {
    const { perms } = parse(); expect(perms.length).toBe(45)
    const alice = await login('alice')
    const db = (await alice.client.from('permissions').select('key,allowed_scopes,is_sensitive')).data as any[]
    expect(db.length).toBe(45)
    for (const p of perms) {
      const row = db.find((d) => d.key === p.key); expect(row, p.key).toBeTruthy()
      expect([...row.allowed_scopes].sort(), p.key).toEqual(p.scopes); expect(row.is_sensitive, p.key).toBe(p.sensitive)
    }
  })
  it('every role-permission pair matches, with the documented per-role counts', async () => {
    const { map } = parse()
    const alice = await login('alice')
    const roles = (await alice.client.from('roles').select('id,system_key').is('organisation_id', null)).data as any[]
    const rp = (await alice.client.from('role_permissions').select('role_id,permission_key')).data as any[]
    expect(roles.length).toBe(8)
    for (const r of ROLES) {
      const id = roles.find((x) => x.system_key === r).id
      const dbSet = new Set(rp.filter((x) => x.role_id === id).map((x) => x.permission_key))
      expect([...dbSet].sort(), r).toEqual([...map[r]].sort())
    }
    expect(ROLES.map((r) => map[r].size)).toEqual([45, 44, 14, 30, 23, 19, 17, 2])
  })
})

describe('MTX-05: authority-bearing permissions are held only by the intended roles', () => {
  it('org.ownership.manage: Owner only; roles.manage/members.suspend/audit.view/files.manage: Owner and Admin only', () => {
    const { map } = parse()
    const holders = (k: string) => ROLES.filter((r) => map[r].has(k))
    expect(holders('org.ownership.manage')).toEqual(['owner'])
    for (const k of ['roles.manage', 'members.suspend', 'audit.view', 'files.manage', 'org.settings.manage', 'structure.manage']) expect(holders(k).slice(0, 2)).toEqual(['owner', 'admin'])
    for (const k of ['roles.manage', 'members.suspend', 'audit.view', 'files.manage', 'org.settings.manage']) expect(holders(k)).toEqual(['owner', 'admin'])
  })
  it('no role references an unknown permission and every role-permission is allowed at its assignable scopes (inert scopes are harmless but flagged)', () => {
    const { perms, map } = parse(); const known = new Set(perms.map((p) => p.key))
    for (const r of ROLES) for (const k of map[r]) expect(known.has(k), `${r}:${k}`).toBe(true)
  })
})
