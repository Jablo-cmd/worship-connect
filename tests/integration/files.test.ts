// FIL-*: file registry and private storage (DATABASE_TESTING_STRATEGY.md 3.13). Phase 1 read rule: uploader only.
// Tests that need a file to become `available` use the service-role client (fixtures ONLY, as the scanner would); they are
// skipped when SUPABASE_SERVICE_ROLE_KEY is not set (e.g. a hosted dev project) - run them against the local stack in CI.
import { describe, it, expect, inject } from 'vitest'
import { login, rows, denied, errText, adminClient } from '../helpers/clients'

const w = inject('world')
const admin = adminClient()
const BUCKET = 'org-files'
const reg = async (who: string, org = w.orgA, over: Record<string, unknown> = {}) => {
  const a = await login(who)
  return a.client.rpc('register_file', { p_org: org, p_filename: 'chart.pdf', p_mime: 'application/pdf', p_size: 1234, p_purpose: 'other', ...over })
}
const upload = async (who: string, path: string, body = '%PDF-test', upsert = false) =>
  (await login(who)).client.storage.from(BUCKET).upload(path, new Blob([body], { type: 'application/pdf' }), { contentType: 'application/pdf', upsert })

describe('FIL: registration', () => {
  it('registers a pending file with a server-generated path {org}/{id}/{safe-name} (FIL-06)', async () => {
    const r = await reg('dan'); expect(r.error, errText(r)).toBeNull()
    const f = (r.data as any[])[0]
    expect(f.storage_path.startsWith(`${w.orgA}/${f.file_id}/`)).toBe(true)
    const row = (await (await login('dan')).client.from('files').select('status,scan_status').eq('id', f.file_id).single()).data as any
    expect(row).toMatchObject({ status: 'pending_upload', scan_status: 'not_scanned' })
  })
  it('filenames are sanitised: no path traversal or extra segments', async () => {
    const f = ((await reg('dan', w.orgA, { p_filename: '../../etc/passwd.pdf' })).data as any[])[0]
    expect(f.storage_path.split('/').length).toBe(3)
    expect(f.storage_path).not.toMatch(/\.\.\/|\\/)
  })
  it('rejects disallowed MIME types, empty/oversized files and unknown purposes', async () => {
    expect((await reg('dan', w.orgA, { p_mime: 'application/x-msdownload' })).error).not.toBeNull()
    expect((await reg('dan', w.orgA, { p_size: 0 })).error).not.toBeNull()
    expect((await reg('dan', w.orgA, { p_size: 52428801 })).error).not.toBeNull()
    expect((await reg('dan', w.orgA, { p_purpose: 'malware' })).error).not.toBeNull()
  })
  it('only active members can register; other organisation / outsider / pending invitee cannot (FIL-05)', async () => {
    for (const who of ['judy', 'mallory']) expect((await reg(who, w.orgA)).error, who).not.toBeNull()
  })
  it('abuse guard: at most 20 pending uploads per user', async () => {
    let last: any
    for (let i = 0; i < 22; i++) { last = await reg('carol'); if (last.error) break }
    expect(errText(last)).toBe('quota_exceeded')
  })
  it('registry rows are private to the uploader: not even the Owner (files.manage) can list them', async () => {
    const [alice, carol, dan] = [await login('alice'), await login('carol'), await login('dan')]
    expect(rows(await dan.client.from('files').select('id'))).toBeGreaterThan(0)
    expect(rows(await alice.client.from('files').select('id').eq('uploaded_by_user_id', dan.uid))).toBe(0)
    expect(rows(await carol.client.from('files').select('id').eq('uploaded_by_user_id', dan.uid))).toBe(0)
  })
  it('clients cannot write the registry directly or mark files available (FIL-10)', async () => {
    const dan = await login('dan')
    const f = ((await reg('dan')).data as any[])[0]
    expect((await dan.client.from('files').update({ status: 'available', scan_status: 'clean' }).eq('id', f.file_id).select()).error).not.toBeNull()
    expect((await dan.client.from('files').insert({ organisation_id: w.orgA, storage_path: 'x', original_filename: 'x', mime_type: 'application/pdf', size_bytes: 1, purpose: 'other' })).error).not.toBeNull()
    expect((await dan.client.from('files').delete().eq('id', f.file_id)).error).not.toBeNull()
  })
})

describe('FIL: storage upload rules', () => {
  it('the registered uploader can upload once; nobody can overwrite (FIL-06c/e)', async () => {
    const f = ((await reg('erin')).data as any[])[0]
    expect((await upload('erin', f.storage_path)).error).toBeNull()
    expect((await upload('erin', f.storage_path, 'overwrite', true)).error).not.toBeNull()
    expect((await upload('erin', f.storage_path, 'again')).error).not.toBeNull()
  })
  it("uploads to unregistered paths, other organisations' prefixes or someone else's pending path are denied (FIL-06a/b/d)", async () => {
    const f = ((await reg('dan')).data as any[])[0]
    expect((await upload('judy', `${w.orgA}/${crypto.randomUUID()}/evil.pdf`)).error).not.toBeNull()
    expect((await upload('dan', `${w.orgA}/${crypto.randomUUID()}/unregistered.pdf`)).error).not.toBeNull()
    expect((await upload('erin', f.storage_path)).error).not.toBeNull()                          // dan's pending path
    expect((await upload('judy', f.storage_path)).error).not.toBeNull()
    expect((await upload('dan', `${w.orgB}/${f.file_id}/x.pdf`)).error).not.toBeNull()          // path org != file org
  })
  it('a file that is not yet available cannot be read by anyone, including its uploader (FIL-08)', async () => {
    const f = ((await reg('dan')).data as any[])[0]
    expect((await upload('dan', f.storage_path)).error).toBeNull()
    for (const who of ['dan', 'alice', 'judy']) expect((await (await login(who)).client.storage.from(BUCKET).download(f.storage_path)).data, who).toBeNull()
  })
  it('listing never reveals other organisations’ or other users’ objects (FIL-11)', async () => {
    const [judy, alice] = [await login('judy'), await login('alice')]
    expect(((await judy.client.storage.from(BUCKET).list(w.orgA)).data ?? []).length).toBe(0)
    expect(((await judy.client.storage.from(BUCKET).list('')).data ?? []).length).toBe(0)
    expect(((await alice.client.storage.from(BUCKET).list(w.orgA)).data ?? []).length).toBe(0)
  })
  it('clients cannot delete objects (no DELETE policy)', async () => {
    const f = ((await reg('dan')).data as any[])[0]; await upload('dan', f.storage_path)
    const r = await (await login('dan')).client.storage.from(BUCKET).remove([f.storage_path])
    expect((r.data ?? []).length).toBe(0)
  })
})

describe.skipIf(!admin)('FIL: reads of AVAILABLE files (needs the service-role fixture to play the scanner)', () => {
  const finalise = async (id: string, status = 'available', scan = 'clean') =>
    expect((await admin!.from('files').update({ status, scan_status: scan }).eq('id', id)).error).toBeNull()

  it('only the uploader can read an available file; Owner, Admin, leaders, other members and other organisations cannot (FIL-02/04/01)', async () => {
    const f = ((await reg('dan')).data as any[])[0]; await upload('dan', f.storage_path); await finalise(f.file_id)
    const dl = async (who: string) => !!(await (await login(who)).client.storage.from(BUCKET).download(f.storage_path)).data
    expect(await dl('dan')).toBe(true)
    for (const who of ['alice', 'bob', 'carol', 'dora', 'erin', 'judy', 'mallory']) expect(await dl(who), who).toBe(false)   // files.manage is NOT a read path
    const sign = async (who: string) => !!(await (await login(who)).client.storage.from(BUCKET).createSignedUrl(f.storage_path, 60)).data?.signedUrl
    expect(await sign('dan')).toBe(true); expect(await sign('alice')).toBe(false); expect(await sign('judy')).toBe(false)
  })
  it('quarantined / infected / rejected files are unreadable by everyone (FIL-13)', async () => {
    for (const [status, scan] of [['quarantined', 'clean'], ['available', 'infected'], ['rejected', 'error']] as const) {
      const f = ((await reg('dan')).data as any[])[0]; await upload('dan', f.storage_path); await finalise(f.file_id, status, scan)
      expect((await (await login('dan')).client.storage.from(BUCKET).download(f.storage_path)).data, `${status}/${scan}`).toBeNull()
    }
  })
  it('delete_file: uploader or files.manage holder may soft-delete; others may not; deleted files are unreadable', async () => {
    const [dan, alice, carol] = [await login('dan'), await login('alice'), await login('carol')]
    const f = ((await reg('dan')).data as any[])[0]; await upload('dan', f.storage_path); await finalise(f.file_id)
    expect((await carol.client.rpc('delete_file', { p_file: f.file_id })).error).not.toBeNull()
    expect((await alice.client.rpc('delete_file', { p_file: f.file_id })).error).toBeNull()           // files.manage: delete only
    expect((await dan.client.storage.from(BUCKET).download(f.storage_path)).data).toBeNull()
  })
  it('a suspended or removed member loses access to files they could read (FIL-05)', async () => {
    const [alice, felix] = [await login('alice'), await login('felix')]
    const f = ((await reg('felix')).data as any[])[0]; await upload('felix', f.storage_path); await finalise(f.file_id)
    expect((await felix.client.storage.from(BUCKET).download(f.storage_path)).data).not.toBeNull()
    await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'suspended' })
    try {
      expect((await felix.client.storage.from(BUCKET).download(f.storage_path)).data).toBeNull()
      expect((await felix.client.storage.from(BUCKET).createSignedUrl(f.storage_path, 60)).data).toBeNull()
    } finally { await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'active' }) }
  })
})
