import { beforeEach, describe, expect, test } from 'bun:test';

process.env.VITE_SUPABASE_URL = 'https://proj.supabase.test';
process.env.VITE_SUPABASE_ANON_KEY = 'anon-key';

const store = new Map<string, string>();
(globalThis as any).localStorage = {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, v),
  removeItem: (k: string) => void store.delete(k),
};

type Call = { url: string; init: any };
let calls: Call[] = [];
let handler: (c: Call) => { status?: number; body?: unknown } | 'network';
(globalThis as any).fetch = async (url: string, init: any) => {
  const c = { url, init };
  calls.push(c);
  const r = handler(c);
  if (r === 'network') throw new TypeError('network down');
  const status = r.status ?? 200;
  return { ok: status >= 200 && status < 300, status, text: async () => (r.body === undefined ? '' : JSON.stringify(r.body)) };
};

const online = await import('../src/lib/online');
const now = () => Math.floor(Date.now() / 1000);
const session = (over: Record<string, unknown> = {}) => ({ access_token: 'AT', refresh_token: 'RT', expires_in: 3600, user: { id: 'u1' }, ...over });

beforeEach(async () => {
  store.clear();
  calls = [];
  await online.onlineSignOut().catch(() => undefined);
  store.clear();
  online.reloadSessionFromStorage();
  calls = [];
});

/** put a session in storage the way a previous app run would have left it */
const seed = (s: Record<string, unknown>) => {
  store.set('margins.sb', JSON.stringify(s));
  online.reloadSessionFromStorage();
};

describe('mapError', () => {
  test('maps database errors to codes', () => {
    expect(online.mapError(400, { code: 'P0001', message: 'handle_cooldown' }).code).toBe('handleCooldown');
    expect(online.mapError(409, { code: '23505', message: 'duplicate key value violates unique constraint "profiles_handle_key"' }).code).toBe('handleTaken');
    expect(online.mapError(400, { code: 'P0001', message: 'handle_reserved' }).code).toBe('handleReserved');
    expect(online.mapError(400, { code: '23514', message: 'violates check constraint "profiles_handle_format" handle' }).code).toBe('handleInvalid');
    expect(online.mapError(429, {}).code).toBe('rateLimited');
    expect(online.mapError(401, { message: 'JWT expired' }).code).toBe('sessionExpired');
    expect(online.mapError(500, { message: 'boom' }).code).toBe('unknown');
  });
});

describe('sessions', () => {
  test('is configured from the environment', () => {
    expect(online.onlineConfigured).toBe(true);
  });

  test('exchanges the Google ID token and stores the session', async () => {
    handler = () => ({ body: session() });
    await online.signInWithGoogleIdToken('GOOGLE-ID-TOKEN');
    expect(calls[0].url).toBe('https://proj.supabase.test/auth/v1/token?grant_type=id_token');
    expect(JSON.parse(calls[0].init.body)).toEqual({ provider: 'google', id_token: 'GOOGLE-ID-TOKEN' });
    expect(calls[0].init.headers.apikey).toBe('anon-key');
    expect(online.hasSession()).toBe(true);
    expect(online.sessionUserId()).toBe('u1');
  });

  test('never sends a service key: only the anon key and the user token', async () => {
    handler = (c) => (c.url.includes('/auth/') ? { body: session() } : { body: [] });
    await online.signInWithGoogleIdToken('t');
    await online.fetchMyProfile();
    for (const c of calls) expect(JSON.stringify(c.init.headers)).not.toMatch(/service/i);
    expect(calls[1].init.headers.Authorization).toBe('Bearer AT');
  });

  test('an empty ID token is refused without a request', async () => {
    handler = () => ({ body: session() });
    await expect(online.signInWithGoogleIdToken('')).rejects.toMatchObject({ code: 'notSignedIn' });
    expect(calls.length).toBe(0);
  });

  test('offline is reported as offline, not as a crash', async () => {
    handler = () => 'network';
    await expect(online.signInWithGoogleIdToken('t')).rejects.toMatchObject({ code: 'offline' });
    expect(online.hasSession()).toBe(false);
  });

  test('refreshes an expired access token before the call', async () => {
    seed({ access_token: 'OLD', refresh_token: 'RT', expires_at: now() - 10, user_id: 'u1' });
    handler = (c) => (c.url.includes('refresh_token') ? { body: session({ access_token: 'NEW', refresh_token: 'RT2' }) } : { body: [{ id: 'u1', handle: 'h', display_name: 'n', bio: '' }] });
    const p = await online.fetchMyProfile();
    expect(p?.handle).toBe('h');
    expect(calls[0].url).toContain('grant_type=refresh_token');
    expect(calls[1].init.headers.Authorization).toBe('Bearer NEW');
  });

  test('a refresh token Supabase rejects ends the session', async () => {
    seed({ access_token: 'OLD', refresh_token: 'BAD', expires_at: now() - 10, user_id: 'u1' });
    handler = () => ({ status: 400, body: { error_description: 'Invalid Refresh Token' } });
    await expect(online.fetchMyProfile()).rejects.toMatchObject({ code: 'sessionExpired' });
    expect(online.hasSession()).toBe(false);
  });

  test('offline during refresh keeps the session', async () => {
    seed({ access_token: 'OLD', refresh_token: 'RT', expires_at: now() - 10, user_id: 'u1' });
    handler = () => 'network';
    await expect(online.fetchMyProfile()).rejects.toMatchObject({ code: 'offline' });
    expect(online.hasSession()).toBe(true);
  });

  test('without a session nothing is sent', async () => {
    handler = () => ({ body: [] });
    await expect(online.fetchMyProfile()).rejects.toMatchObject({ code: 'notSignedIn' });
    expect(calls.length).toBe(0);
  });
});

describe('profile calls', () => {
  beforeEach(() => seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3000, user_id: 'u1' }));

  test('create_profile sends a normalised handle', async () => {
    handler = () => ({ body: { id: 'u1', handle: 'alice', display_name: 'Alice', bio: '', handle_changed_at: null } });
    const p = await online.createProfile(' @Alice ', ' Alice ', ' hi ');
    expect(calls[0].url).toBe('https://proj.supabase.test/rest/v1/rpc/create_profile');
    expect(JSON.parse(calls[0].init.body)).toEqual({ p_handle: 'alice', p_display_name: 'Alice', p_bio: 'hi' });
    expect(Object.keys(p).sort()).toEqual(['bio', 'display_name', 'handle', 'id']);
  });

  test('taken handle surfaces as handleTaken', async () => {
    handler = () => ({ status: 409, body: { code: '23505', message: 'duplicate key value violates unique constraint "profiles_handle_key"' } });
    await expect(online.createProfile('alice', 'A', '')).rejects.toMatchObject({ code: 'handleTaken' });
  });

  test('update only touches the own row', async () => {
    handler = () => ({ body: [{ id: 'u1', handle: 'a', display_name: 'New', bio: 'b' }] });
    await online.updateMyProfile('New', 'b');
    expect(calls[0].url).toContain('/rest/v1/profiles?id=eq.u1');
    expect(calls[0].init.method).toBe('PATCH');
    expect(JSON.parse(calls[0].init.body)).toEqual({ display_name: 'New', bio: 'b' });
  });

  test('delete account clears the local session', async () => {
    handler = () => ({ status: 204 });
    await online.deleteOnlineAccount();
    expect(calls[0].url).toContain('/rpc/delete_my_account');
    expect(online.hasSession()).toBe(false);
  });
});
