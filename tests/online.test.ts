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
let handler: (c: Call) => { status?: number; body?: unknown; raw?: Uint8Array } | 'network';
(globalThis as any).fetch = async (url: string, init: any) => {
  const c = { url, init };
  calls.push(c);
  const r = handler(c);
  if (r === 'network') throw new TypeError('network down');
  const status = r.status ?? 200;
  const raw = (r as { raw?: Uint8Array }).raw;
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    text: async () => (r.body === undefined ? '' : JSON.stringify(r.body)),
    blob: async () => new Blob([raw ?? new Uint8Array(0)]),
  };
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

describe('base url', () => {
  test('tolerates trailing slash and the /rest/v1 suffix', () => {
    expect(online.cleanBaseUrl('https://x.supabase.co/rest/v1/')).toBe('https://x.supabase.co');
    expect(online.cleanBaseUrl(' https://x.supabase.co/ ')).toBe('https://x.supabase.co');
    expect(online.cleanBaseUrl('https://x.supabase.co')).toBe('https://x.supabase.co');
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

  test('a publishable (non-JWT) key is sent as apikey only, never as bearer', async () => {
    handler = () => ({ body: session() });
    await online.signInWithGoogleIdToken('t');
    expect(calls[0].init.headers.apikey).toBe('anon-key');
    expect(calls[0].init.headers.Authorization).toBeUndefined();
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
    handler = (c) => (c.url.includes('/rest/v1/books') ? { body: [{ id: 'b1', format: 'epub' }] } : { status: 204 });
    await online.deleteOnlineAccount();
    // stored files are removed first, then the account
    expect(calls.some((c) => c.url.includes('/storage/v1/object/books') && c.init.method === 'DELETE')).toBe(true);
    expect(calls[calls.length - 1].url).toContain('/rpc/delete_my_account');
    expect(online.hasSession()).toBe(false);
  });

  test('delete account still goes ahead when file removal fails', async () => {
    handler = (c) => (c.url.includes('/rest/v1/books') ? { status: 500, body: {} } : { status: 204 });
    await online.deleteOnlineAccount();
    expect(calls[calls.length - 1].url).toContain('/rpc/delete_my_account');
  });
});

describe('library & shelves', () => {
  beforeEach(() => seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3000, user_id: 'u1' }));

  test('reads only my library and shelves, ordered', async () => {
    handler = (c) => ({ body: c.url.includes('/libraries') ? [{ id: 'L', title: '', description: '', default_access: 'private' }] : [] });
    const lib = await online.fetchMyLibrary();
    expect(lib.default_access).toBe('private');
    await online.listMyShelves();
    expect(calls[0].url).toContain('/rest/v1/libraries?owner_id=eq.u1');
    expect(calls[1].url).toContain('/rest/v1/shelves?owner_id=eq.u1');
    expect(calls[1].url).toContain('order=position.asc');
  });

  test('a missing library is notFound', async () => {
    handler = () => ({ body: [] });
    await expect(online.fetchMyLibrary()).rejects.toMatchObject({ code: 'notFound' });
  });

  test('createShelf sends owner, library, trimmed name', async () => {
    handler = () => ({ body: [{ id: 's1', name: 'Novels', description: '', position: 3, access: 'inherit' }] });
    const s = await online.createShelf('L', '  Novels ', ' ', 3);
    expect(calls[0].init.method).toBe('POST');
    expect(JSON.parse(calls[0].init.body)).toEqual({ library_id: 'L', owner_id: 'u1', name: 'Novels', description: '', position: 3 });
    expect(s.access).toBe('inherit');
  });

  test('updateShelf patches only the given fields', async () => {
    handler = () => ({ body: [{ id: 's1', name: 'X', description: '', position: 0, access: 'private' }] });
    await online.updateShelf('s1', { access: 'private' });
    expect(calls[0].init.method).toBe('PATCH');
    expect(calls[0].url).toContain('/rest/v1/shelves?id=eq.s1');
    expect(JSON.parse(calls[0].init.body)).toEqual({ access: 'private' });
  });

  test('deleteShelf and reorder', async () => {
    handler = () => ({ status: 204 });
    await online.deleteShelf('s1');
    expect(calls[0].init.method).toBe('DELETE');
    await online.reorderShelves(['b', 'a']);
    expect(calls[1].url).toContain('/rpc/reorder_shelves');
    expect(JSON.parse(calls[1].init.body)).toEqual({ p_ids: ['b', 'a'] });
  });

  test('password calls use the RPCs and map password_invalid', async () => {
    handler = (c) => (c.url.includes('set_access_password') ? { status: 400, body: { code: 'P0001', message: 'password_invalid' } } : { body: true });
    await expect(online.setAccessPassword('shelf', 's1', 'short')).rejects.toMatchObject({ code: 'passwordInvalid' });
    expect(await online.hasAccessPassword('shelf', 's1')).toBe(true);
    expect(JSON.parse(calls[1].init.body)).toEqual({ p_type: 'shelf', p_id: 's1' });
  });
});

describe('books', () => {
  beforeEach(() => seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3000, user_id: 'u1' }));
  const H = 'a'.repeat(64);

  test('createBookRecord sends owner, hash, rights time and no file status', async () => {
    handler = () => ({ body: [{ id: 'b1', title: 'T', author: '', description: '', language: null, format: 'epub', file_size: 5, file_status: 'pending', access: 'inherit', read_allowed: false, download_allowed: false }] });
    const b = await online.createBookRecord({ title: '  T ', format: 'epub', hash: H, size: 5 });
    const sent = JSON.parse(calls[0].init.body);
    expect(sent.owner_id).toBe('u1');
    expect(sent.file_hash).toBe(H);
    expect(sent.title).toBe('T');
    expect(typeof sent.rights_confirmed_at).toBe('string');
    expect('file_status' in sent).toBe(false);
    expect(b.file_status).toBe('pending');
  });

  test('a duplicate file is mapped to duplicate', async () => {
    handler = () => ({ status: 409, body: { code: '23505', message: 'duplicate key value violates unique constraint "books_owner_id_file_hash_key"' } });
    await expect(online.createBookRecord({ title: 'T', format: 'pdf', hash: H, size: 5 })).rejects.toMatchObject({ code: 'duplicate' });
  });

  test('updateBook patches only the sent fields', async () => {
    handler = () => ({ body: [{ id: 'b1', title: 'T', author: '', description: '', language: null, format: 'pdf', file_size: 5, file_status: 'pending', access: 'friends', read_allowed: true, download_allowed: false }] });
    await online.updateBook('b1', { access: 'friends', read_allowed: true });
    expect(calls[0].init.method).toBe('PATCH');
    expect(JSON.parse(calls[0].init.body)).toEqual({ access: 'friends', read_allowed: true });
  });

  test('shelf membership calls', async () => {
    handler = () => ({ body: [{ shelf_id: 's', book_id: 'b', position: 2 }] });
    await online.addBookToShelf('s', 'b', 2);
    expect(JSON.parse(calls[0].init.body)).toEqual({ shelf_id: 's', book_id: 'b', owner_id: 'u1', position: 2 });
    handler = () => ({ status: 204 });
    await online.removeBookFromShelf('s', 'b');
    expect(calls[1].init.method).toBe('DELETE');
    expect(calls[1].url).toContain('shelf_id=eq.s&book_id=eq.b');
    await online.setShelfBookPosition('s', 'b', 0);
    expect(calls[2].init.method).toBe('PATCH');
  });

  test('lists only my books and links', async () => {
    handler = () => ({ body: [] });
    await online.listMyBooks();
    await online.listMyShelfLinks();
    expect(calls[0].url).toContain('/rest/v1/books?owner_id=eq.u1');
    expect(calls[1].url).toContain('/rest/v1/shelf_books?owner_id=eq.u1');
  });
});

describe('upload', () => {
  beforeEach(() => seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3000, user_id: 'u1' }));
  const book = { id: 'b1', format: 'epub' as const, file_size: 4 };
  const blob = new Blob([new Uint8Array(4)]);

  test('uploads to the owner path, then finalizes', async () => {
    handler = (c) => (c.url.includes('finalize_book_upload') ? { body: 'ready' } : { body: { Key: 'x' } });
    await online.publishBookFile(book, blob, undefined);
    expect(calls[0].url).toContain('/storage/v1/object/books/u1/b1.epub');
    expect(calls[0].init.headers['Content-Type']).toBe('application/epub+zip');
    expect(calls[0].init.headers['x-upsert']).toBe('true');
    expect(calls[1].url).toContain('/rpc/finalize_book_upload');
  });

  test('a failed verification is an error', async () => {
    handler = (c) => (c.url.includes('finalize_book_upload') ? { body: 'failed' } : { body: {} });
    await expect(online.publishBookFile(book, blob, undefined)).rejects.toMatchObject({ code: 'uploadFailed' });
  });

  test('size mismatch is refused before any request', async () => {
    handler = () => ({ body: {} });
    await expect(online.publishBookFile({ ...book, file_size: 5 }, blob, undefined)).rejects.toMatchObject({ code: 'uploadFailed' });
    expect(calls.length).toBe(0);
  });

  test('413 maps to tooLarge; a storage 403 is uploadFailed', async () => {
    handler = () => ({ status: 413, body: { statusCode: '413', message: 'The object exceeded the maximum allowed size' } });
    await expect(online.uploadObject('books', 'u1/b1.epub', blob, 'application/pdf')).rejects.toMatchObject({ code: 'tooLarge' });
    handler = () => ({ status: 403, body: { statusCode: '403', message: 'new row violates row-level security policy' } });
    await expect(online.uploadObject('books', 'u1/b1.epub', blob, 'application/pdf')).rejects.toMatchObject({ code: 'uploadFailed' });
  });

  test('a cover failure does not block the book', async () => {
    handler = (c) => (c.url.includes('/covers/') ? { status: 400, body: { message: 'x' } } : c.url.includes('finalize') ? { body: 'ready' } : { body: {} });
    await online.publishBookFile(book, blob, new Blob([new Uint8Array(2)]));
  });

  test('hashes map and file removal', async () => {
    handler = (c) => (c.url.includes('my_book_hashes') ? { body: [{ id: 'b1', file_hash: 'h' }] } : { status: 200, body: [] });
    expect((await online.myBookHashes()).get('b1')).toBe('h');
    await online.removeBookFiles([{ id: 'b1', format: 'pdf' }]);
    expect(JSON.parse(calls[1].init.body)).toEqual({ prefixes: ['u1/b1.pdf'] });
    expect(calls[1].init.method).toBe('DELETE');
  });
});

describe('visiting (stage 3b)', () => {
  const owner = 'o1';
  const vbook = { id: 'b1', owner_id: owner, format: 'epub' as const, file_size: 4 };

  test('a signed-out visitor opens a library with the anon key; the handle is normalised', async () => {
    handler = () => ({ body: { profile: { id: owner, handle: 'alice', display_name: 'A', bio: '' }, library: { id: 'l1', state: 'open' } } });
    const r = await online.visitLibrary('  @Alice ');
    expect(r.library.state).toBe('open');
    expect(r.shelves).toEqual([]);
    expect(r.locked_books).toEqual([]);
    expect(calls[0].url).toContain('/rest/v1/rpc/visit_library');
    expect(JSON.parse(calls[0].init.body)).toEqual({ p_handle: 'alice' });
    expect(calls[0].init.headers.apikey).toBe('anon-key');
  });

  test('a signed-in visitor uses her own token', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ body: { profile: { id: owner, handle: 'alice', display_name: 'A', bio: '' }, library: { id: 'l1', state: 'locked' } } });
    await online.visitLibrary('alice');
    expect(calls[0].init.headers.Authorization).toBe('Bearer AT');
  });

  test('unknown / blocked handle is notFound; an empty handle never reaches the network', async () => {
    handler = () => ({ status: 400, body: { code: 'P0001', message: 'not_found' } });
    await expect(online.visitLibrary('ghost')).rejects.toMatchObject({ code: 'notFound' });
    calls = [];
    await expect(online.visitLibrary('  @ ')).rejects.toMatchObject({ code: 'notFound' });
    expect(calls.length).toBe(0);
  });

  test('visible books: only ready ones, and the list is paged', async () => {
    const page = (n: number, status = 'ready') => Array.from({ length: n }, (_, i) => ({ id: `b${i}`, file_status: status }));
    let n = 0;
    handler = (c) => {
      n++;
      expect(c.url).toContain('owner_id=eq.o1');
      return { body: n === 1 ? page(1000) : [...page(2), { id: 'x', file_status: 'pending' }] };
    };
    const list = await online.listVisitedBooks(owner);
    expect(list.length).toBe(1002);
    expect(calls[1].url).toContain('offset=1000');
  });

  test('redeeming a password: true, false, and the profile-required case', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ body: true });
    expect(await online.redeemPassword('shelf', 's1', 'pw-pw-pw-1')).toBe(true);
    expect(JSON.parse(calls[0].init.body)).toEqual({ p_type: 'shelf', p_id: 's1', p_password: 'pw-pw-pw-1' });
    handler = () => ({ body: false });
    expect(await online.redeemPassword('book', 'b1', 'x')).toBe(false);
    handler = () => ({ status: 409, body: { code: '23503', message: 'insert or update on table "access_grants" violates foreign key constraint' } });
    await expect(online.redeemPassword('book', 'b1', 'x')).rejects.toMatchObject({ code: 'profileRequired' });
    store.clear();
    online.reloadSessionFromStorage();
    await expect(online.redeemPassword('book', 'b1', 'x')).rejects.toMatchObject({ code: 'notSignedIn' });
  });

  test('downloading uses the session token on the authenticated route (no signed link)', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ raw: new Uint8Array(4) });
    const blob = await online.downloadBookFile(vbook);
    expect(blob.size).toBe(4);
    expect(calls[0].url).toBe('https://proj.supabase.test/storage/v1/object/authenticated/books/o1/b1.epub');
    expect(calls[0].init.headers.Authorization).toBe('Bearer AT');
    expect(calls[0].url).not.toContain('token=');
  });

  test('a file of the wrong size is refused', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ raw: new Uint8Array(9) });
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'fileUnavailable' });
  });

  test('download errors: denied -> fileUnavailable, 429, 5xx, offline, signed out', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ status: 400, body: { statusCode: '404', error: 'not_found' } });
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'fileUnavailable' });
    handler = () => ({ status: 429 });
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'rateLimited' });
    handler = () => ({ status: 503 });
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'unknown' });
    handler = () => 'network';
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'offline' });
    store.clear();
    online.reloadSessionFromStorage();
    await expect(online.downloadBookFile(vbook)).rejects.toMatchObject({ code: 'notSignedIn' });
  });

  test('an expired token is refreshed once and the download retried', async () => {
    seed({ access_token: 'OLD', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = (c) => (c.url.includes('grant_type=refresh_token') ? { body: session({ access_token: 'NEW' }) } : c.init.headers.Authorization === 'Bearer OLD' ? { status: 401 } : { raw: new Uint8Array(4) });
    expect((await online.downloadBookFile(vbook)).size).toBe(4);
    expect(calls.at(-1)!.init.headers.Authorization).toBe('Bearer NEW');
  });

  test('covers: fetched from the covers bucket, cached, a failure is null and retried later', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    online.clearCoverCache();
    handler = () => ({ raw: new Uint8Array(3) });
    expect((await online.fetchCover(owner, 'c1'))!.size).toBe(3);
    await online.fetchCover(owner, 'c1');
    expect(calls.filter((c) => c.url.includes('/covers/o1/c1.jpg')).length).toBe(1);
    handler = () => ({ status: 400, body: {} });
    expect(await online.fetchCover(owner, 'c2')).toBeNull();
    handler = () => ({ raw: new Uint8Array(1) });
    expect((await online.fetchCover(owner, 'c2'))!.size).toBe(1);
  });
});


describe('discovery (stage 3c)', () => {
  const row = (i: number) => ({ id: `b${i}`, owner_id: 'o1', title: `T${i}`, author: '', description: '', language: null, format: 'epub', file_size: 10, file_status: 'ready', has_cover: false, read_allowed: true, download_allowed: false, owner_handle: 'alice', owner_name: 'Alice' });

  test('a signed-out visitor searches with the anon key; the query is cleaned; one extra row is requested', async () => {
    handler = () => ({ body: [] });
    await online.discoverBooks('  dune   saga ');
    const c = calls.at(-1)!;
    expect(c.url).toContain('/rest/v1/rpc/discover_books');
    expect(JSON.parse(c.init.body)).toEqual({ p_query: 'dune saga', p_limit: 31, p_offset: 0 });
    expect(c.init.headers.Authorization).toBeUndefined();
    expect(c.init.headers.apikey).toBeTruthy();
  });

  test('a signed-in visitor uses her own token (so blocks apply)', async () => {
    seed({ access_token: 'AT', refresh_token: 'RT', expires_at: now() + 3600, user_id: 'u1' });
    handler = () => ({ body: [] });
    await online.discoverLibraries('x');
    expect(calls.at(-1)!.init.headers.Authorization).toBe('Bearer AT');
    expect(calls.at(-1)!.url).toContain('/rest/v1/rpc/discover_libraries');
  });

  test('paging: the extra row only says "more", it is never shown; offset is sent', async () => {
    handler = () => ({ body: Array.from({ length: 31 }, (_, i) => row(i)) });
    const p = await online.discoverBooks('', 0);
    expect(p.items.length).toBe(30);
    expect(p.more).toBe(true);
    handler = () => ({ body: [row(1), row(2)] });
    const q = await online.discoverBooks('', 30);
    expect(q.more).toBe(false);
    expect(JSON.parse(calls.at(-1)!.init.body).p_offset).toBe(30);
    expect((await online.discoverBooks('', -7).then(() => JSON.parse(calls.at(-1)!.init.body))).p_offset).toBe(0);
  });

  test('the query is cut to 120 characters; a null body is an empty page', async () => {
    handler = () => ({ body: null });
    const p = await online.discoverBooks('x'.repeat(500));
    expect(p).toEqual({ items: [], more: false });
    expect(JSON.parse(calls.at(-1)!.init.body).p_query.length).toBe(120);
  });

  test('libraries: the count arrives as a number even when Postgres sends bigint as a string', async () => {
    handler = () => ({ body: [{ handle: 'alice', display_name: 'A', bio: '', library_title: 'L', library_description: '', book_count: '4' }] });
    const p = await online.discoverLibraries('');
    expect(p.items[0].book_count).toBe(4);
  });

  test('errors are mapped: offline, rate limit, server', async () => {
    handler = () => 'network';
    await expect(online.discoverBooks('')).rejects.toMatchObject({ code: 'offline' });
    handler = () => ({ status: 429, body: {} });
    await expect(online.discoverBooks('')).rejects.toMatchObject({ code: 'rateLimited' });
    handler = () => ({ status: 500, body: { message: 'boom' } });
    await expect(online.discoverLibraries('')).rejects.toMatchObject({ code: 'unknown' });
  });
});
