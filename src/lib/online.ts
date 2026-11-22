/**
 * Online account (Supabase). Sign-in is the Google account the app already uses: the Google ID token is
 * exchanged for a Supabase session. No SDK and no password: plain `fetch` against the public REST API with
 * the PUBLIC anon key; every permission is enforced by the database (row-level security), never by this code.
 *
 * Local-first: nothing here is awaited by the reader or the library. Every call can fail (offline, not
 * configured, session expired) and the app keeps working.
 */
import { normalizeHandle } from './handle';

const URL_BASE = ((import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '').replace(/\/+$/, '');
const ANON_KEY = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '';
const KEY = 'margins.sb';

/** false when the build was made without a Supabase project: the UI says so instead of pretending */
export const onlineConfigured = !!URL_BASE && !!ANON_KEY;

export type OnlineErrorCode =
  | 'notConfigured' | 'offline' | 'notSignedIn' | 'sessionExpired' | 'handleTaken' | 'handleInvalid' | 'handleReserved'
  | 'handleCooldown' | 'alreadyHasProfile' | 'rateLimited' | 'quota' | 'unknown';

export class OnlineError extends Error {
  code: OnlineErrorCode;
  constructor(code: OnlineErrorCode, message?: string) {
    super(message ?? code);
    this.code = code;
  }
}

export interface OnlineProfile {
  id: string;
  handle: string;
  display_name: string;
  bio: string;
}

interface Session {
  access_token: string;
  refresh_token: string;
  /** unix seconds */
  expires_at: number;
  user_id: string;
}

/* ---------------------------------------------------------------- session store */
let mem: Session | null | undefined;

function readSession(): Session | null {
  if (mem !== undefined) return mem;
  try {
    const raw = localStorage.getItem(KEY);
    mem = raw ? (JSON.parse(raw) as Session) : null;
  } catch {
    mem = null;
  }
  return mem;
}

function writeSession(s: Session | null) {
  mem = s;
  try {
    if (s) localStorage.setItem(KEY, JSON.stringify(s));
    else localStorage.removeItem(KEY);
  } catch {
    /* storage unavailable: the session lives until the app closes */
  }
}

/** forget the in-memory copy so the next call re-reads storage (another tab may have changed it) */
export const reloadSessionFromStorage = () => {
  mem = undefined;
};
export const hasSession = () => !!readSession();
export const sessionUserId = () => readSession()?.user_id ?? null;

/* ---------------------------------------------------------------- error mapping */
/** Turns a PostgREST / GoTrue error body into one of our codes. Pure: unit-tested. */
export function mapError(status: number, body: unknown): OnlineError {
  const b = (body ?? {}) as { code?: string; message?: string; error_description?: string; msg?: string };
  const msg = String(b.message ?? b.error_description ?? b.msg ?? '');
  const code = String(b.code ?? '');
  if (/handle_reserved/.test(msg)) return new OnlineError('handleReserved', msg);
  if (/handle_cooldown/.test(msg)) return new OnlineError('handleCooldown', msg);
  if (code === '23505' && /handle/.test(msg)) return new OnlineError('handleTaken', msg);
  if (code === '23505' && /profiles_pkey/.test(msg)) return new OnlineError('alreadyHasProfile', msg);
  if (code === '23514' && /handle/.test(msg)) return new OnlineError('handleInvalid', msg);
  if (/rate_limited|cooldown/.test(msg) || status === 429) return new OnlineError('rateLimited', msg);
  if (/quota_exceeded/.test(msg) || code === '53400') return new OnlineError('quota', msg);
  if (status === 401 || /jwt|not_authenticated/i.test(msg) || code === '28000') return new OnlineError('sessionExpired', msg);
  return new OnlineError('unknown', msg || `HTTP ${status}`);
}

async function send(path: string, init: RequestInit & { json?: unknown } = {}, token?: string): Promise<unknown> {
  if (!onlineConfigured) throw new OnlineError('notConfigured');
  const headers: Record<string, string> = { apikey: ANON_KEY, Authorization: `Bearer ${token ?? ANON_KEY}`, ...(init.headers as Record<string, string>) };
  let body = init.body;
  if (init.json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(init.json);
  }
  let res: Response;
  try {
    res = await fetch(URL_BASE + path, { ...init, headers, body });
  } catch {
    throw new OnlineError('offline');
  }
  const text = await res.text();
  let parsed: unknown = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    /* non-JSON body */
  }
  if (!res.ok) throw mapError(res.status, parsed);
  return parsed;
}

/* ------------------------------------------------------------------- sessions */
function toSession(r: any): Session {
  const expires = Number(r.expires_at) || Math.floor(Date.now() / 1000) + Number(r.expires_in || 3600);
  return { access_token: r.access_token, refresh_token: r.refresh_token, expires_at: expires, user_id: r.user?.id };
}

/** Exchanges the Google ID token of the existing Google sign-in for a Supabase session. */
export async function signInWithGoogleIdToken(idToken: string): Promise<void> {
  if (!idToken) throw new OnlineError('notSignedIn');
  const r = await send('/auth/v1/token?grant_type=id_token', { method: 'POST', json: { provider: 'google', id_token: idToken } });
  writeSession(toSession(r));
}

let refreshing: Promise<Session> | null = null;
async function refresh(s: Session): Promise<Session> {
  refreshing ??= (async () => {
    try {
      const r = await send('/auth/v1/token?grant_type=refresh_token', { method: 'POST', json: { refresh_token: s.refresh_token } });
      const next = toSession(r);
      writeSession(next);
      return next;
    } catch (e) {
      // a refresh token Supabase no longer knows is final; a network failure is not
      if (e instanceof OnlineError && e.code !== 'offline') writeSession(null);
      throw e instanceof OnlineError && e.code !== 'offline' ? new OnlineError('sessionExpired') : e;
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

async function token(): Promise<string> {
  let s = readSession();
  if (!s) throw new OnlineError('notSignedIn');
  if (s.expires_at - 60 < Date.now() / 1000) s = await refresh(s);
  return s.access_token;
}

export async function onlineSignOut(): Promise<void> {
  const s = readSession();
  writeSession(null);
  if (s && onlineConfigured) {
    try {
      await send('/auth/v1/logout?scope=local', { method: 'POST' }, s.access_token);
    } catch {
      /* the local session is already gone */
    }
  }
}

async function authed(path: string, init: RequestInit & { json?: unknown } = {}): Promise<unknown> {
  try {
    return await send(path, init, await token());
  } catch (e) {
    if (e instanceof OnlineError && e.code === 'sessionExpired' && readSession()) {
      // the access token was rejected: try one refresh, then give up
      const s = readSession()!;
      const next = await refresh(s);
      return send(path, init, next.access_token);
    }
    throw e;
  }
}

const rpc = (fn: string, args: Record<string, unknown> = {}) => authed(`/rest/v1/rpc/${fn}`, { method: 'POST', json: args });

/* -------------------------------------------------------------------- profile */
const PROFILE_COLS = 'id,handle,display_name,bio';

export async function fetchMyProfile(): Promise<OnlineProfile | null> {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  const rows = (await authed(`/rest/v1/profiles?id=eq.${encodeURIComponent(uid)}&select=${PROFILE_COLS}`)) as OnlineProfile[];
  return rows[0] ?? null;
}

export async function isHandleAvailable(handle: string): Promise<boolean> {
  return (await rpc('handle_available', { p_handle: normalizeHandle(handle) })) === true;
}

export async function createProfile(handle: string, displayName: string, bio: string): Promise<OnlineProfile> {
  const p = (await rpc('create_profile', { p_handle: normalizeHandle(handle), p_display_name: displayName.trim(), p_bio: bio.trim() })) as OnlineProfile;
  return { id: p.id, handle: p.handle, display_name: p.display_name, bio: p.bio };
}

export async function updateMyProfile(displayName: string, bio: string): Promise<OnlineProfile> {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  const rows = (await authed(`/rest/v1/profiles?id=eq.${encodeURIComponent(uid)}&select=${PROFILE_COLS}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=representation' },
    json: { display_name: displayName.trim(), bio: bio.trim() },
  })) as OnlineProfile[];
  if (!rows[0]) throw new OnlineError('unknown');
  return rows[0];
}

export async function changeHandle(handle: string): Promise<OnlineProfile> {
  const p = (await rpc('change_handle', { p_handle: normalizeHandle(handle) })) as OnlineProfile;
  return { id: p.id, handle: p.handle, display_name: p.display_name, bio: p.bio };
}

/** Deletes the online account and everything stored under it. Local books and the Drive copy are untouched. */
export async function deleteOnlineAccount(): Promise<void> {
  await rpc('delete_my_account');
  writeSession(null);
}
