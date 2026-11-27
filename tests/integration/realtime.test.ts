// RT-*: realtime authorisation (DATABASE_TESTING_STRATEGY.md 3.14). Private Broadcast topics, ID-ONLY payloads.
import { describe, it, expect, inject, afterAll } from 'vitest'
import { login, sleep, type Actor } from '../helpers/clients'

const w = inject('world')
const opened: any[] = []
afterAll(async () => { for (const c of opened) { try { await c.unsubscribe() } catch {} } })

async function sub(a: Actor, topic: string, bag: any[] = []) {
  const ch = a.client.channel(topic, { config: { private: true } })
  ch.on('broadcast', { event: '*' }, (p: any) => bag.push(p))
  const status = await new Promise<string>((res) => {
    ch.subscribe((s: string) => { if (['SUBSCRIBED', 'CHANNEL_ERROR', 'TIMED_OUT', 'CLOSED'].includes(s)) res(s) })
    setTimeout(() => res('TIMEOUT'), 12000)
  })
  if (status !== 'SUBSCRIBED') { try { await a.client.removeChannel(ch) } catch {} }   // a denied/failed join must not linger on the socket
  else opened.push(ch)
  return { ch, status, bag }
}
const meTopic = (org: string, mem: string) => `org:${org}:me:${mem}`

describe('RT: topic authorisation', () => {
  it('a member joins their own personal topic and the organisation presence topic (positive twin)', async () => {
    const dan = await login('dan')
    expect((await sub(dan, meTopic(w.orgA, w.mem.dan.A!))).status).toBe('SUBSCRIBED')
    expect((await sub(dan, `org:${w.orgA}:presence`)).status).toBe('SUBSCRIBED')
  })
  it("nobody joins someone else's personal topic - not a leader, an Owner, or another organisation (RT-01/02)", async () => {
    for (const who of ['carol', 'alice', 'judy', 'mallory']) {
      const a = await login(who)
      expect((await sub(a, meTopic(w.orgA, w.mem.dan.A!))).status, who).not.toBe('SUBSCRIBED')
    }
  })
  it('other organisations and outsiders cannot join A presence (RT-01b)', async () => {
    for (const who of ['judy', 'mallory']) expect((await sub(await login(who), `org:${w.orgA}:presence`)).status, who).not.toBe('SUBSCRIBED')
  })
  it('malformed, wrong-organisation and unknown topics are denied (RT-05)', async () => {
    const dan = await login('dan')
    for (const t of ['org:not-a-uuid:me:xyz', `org:${w.orgB}:presence`, `org:${w.orgA}:unknown:${w.mem.dan.A}`, `org:${w.orgA}:me:${w.mem.dan.B ?? w.mem.carol.A}`, 'public:anything', `org:${w.orgA}:presence:extra`])
      expect((await sub(dan, t)).status, t).not.toBe('SUBSCRIBED')
  })
})

describe('RT: revocation (RT-06) - ids only, database is the source of truth', () => {
  it('suspending a member notifies his personal topic with an id-only payload; he cannot rejoin; reinstatement restores', async () => {
    const [alice, felix] = [await login('alice'), await login('felix')]
    const bag: any[] = []
    const s = await sub(felix, meTopic(w.orgA, w.mem.felix.A!), bag)
    expect(s.status).toBe('SUBSCRIBED')
    expect((await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'suspended', p_reason: 'rt test' })).error).toBeNull()
    try {
      await sleep(3500)
      const ev = bag.find((e) => e.event === 'membership.revoked')
      expect(ev, JSON.stringify(bag.map((e) => e.event))).toBeTruthy()
      expect(JSON.stringify(ev)).not.toMatch(/rt test|reason|display_name|email/)                  // no reason, name or e-mail in the payload
      expect((await sub(felix, meTopic(w.orgA, w.mem.felix.A!))).status).not.toBe('SUBSCRIBED')      // fresh join is denied
    } finally { await alice.client.rpc('set_membership_status', { p_membership: w.mem.felix.A, p_to: 'active' }) }
    await sleep(500)
    expect((await sub(felix, meTopic(w.orgA, w.mem.felix.A!))).status).toBe('SUBSCRIBED')
  })
  it('clients cannot broadcast onto a personal topic (RT-04)', async () => {
    const [dan, erin] = [await login('dan'), await login('erin')]
    const bag: any[] = []
    await sub(dan, meTopic(w.orgA, w.mem.dan.A!), bag)
    const attacker = await sub(erin, meTopic(w.orgA, w.mem.erin.A!))            // erin can join HER topic, but not dan's
    await attacker.ch.send({ type: 'broadcast', event: 'forged', payload: { x: 1 } }).catch(() => null)
    const wrong = erin.client.channel(meTopic(w.orgA, w.mem.dan.A!), { config: { private: true } })
    await new Promise((r) => { wrong.subscribe(() => r(null)); setTimeout(() => r(null), 5000) })
    await wrong.send({ type: 'broadcast', event: 'forged', payload: { x: 2 } }).catch(() => null)
    try { await erin.client.removeChannel(wrong) } catch {}
    await sleep(2500)
    expect(bag.some((e) => e.event === 'forged')).toBe(false)
  })
})
