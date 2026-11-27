import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import WS from 'ws'

export const URL_ = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
export const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? ''
export const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''   // fixtures only; NEVER used for assertions about RLS
export const PASSWORD = 'Wc-Test-Password-1!'                              // public synthetic test value (see supabase/seed.sql)

// Node's `ws` does not read proxy variables; route through the proxy only if one is configured (e.g. sandboxed CI).
let wsTransport: any = WS
const proxy = process.env.HTTPS_PROXY ?? process.env.https_proxy
if (proxy && URL_.startsWith('https://')) {
  const { HttpsProxyAgent } = await import('https-proxy-agent')
  const agent = new HttpsProxyAgent(proxy)
  wsTransport = class extends WS { constructor(url: any, protocols: any) { super(url, protocols, { agent }) } }
}

export function newClient(): SupabaseClient {
  if (!ANON_KEY) throw new Error('SUPABASE_ANON_KEY is not set (see .env.example)')
  return createClient(URL_, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    realtime: { transport: wsTransport },
  })
}
export const adminClient = (): SupabaseClient | null =>
  SERVICE_KEY ? createClient(URL_, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } }) : null

export type Actor = { name: string; client: SupabaseClient; uid: string; token: string }
const cache = new Map<string, Promise<Actor>>()
/** Sign in a synthetic seed user with a REAL password session (a real JWT, exactly as a browser would hold). */
export function login(name: string): Promise<Actor> {
  if (!cache.has(name)) cache.set(name, (async () => {
    const client = newClient()
    const { data, error } = await client.auth.signInWithPassword({ email: `${name}@wc-test.example`, password: PASSWORD })
    if (error || !data.session) throw new Error(`login ${name}: ${error?.message}`)
    await client.realtime.setAuth(data.session.access_token)
    return { name, client, uid: data.user.id, token: data.session.access_token }
  })())
  return cache.get(name)!
}
export const anon = () => newClient()

export const rows = (r: { data: unknown }) => (Array.isArray(r.data) ? r.data.length : r.data ? 1 : 0)
/** A read is "denied" if it errors or returns zero rows; a write is denied if it errors or affects zero rows. */
export const denied = (r: { data: unknown; error: unknown }) => !!r.error || rows(r) === 0
export const errText = (r: { error: { message?: string } | null }) => r.error?.message ?? ''
export const sleep = (ms: number) => new Promise((res) => setTimeout(res, ms))
