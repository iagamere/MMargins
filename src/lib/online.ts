/**
 * Online account (Supabase). Sign-in is the Google account the app already uses: the Google ID token is
 * exchanged for a Supabase session. No SDK and no password: plain `fetch` against the public REST API with
 * the PUBLIC anon key; every permission is enforced by the database (row-level security), never by this code.
 *
 * Local-first: nothing here is awaited by the reader or the library. Every call can fail (offline, not
 * configured, session expired) and the app keeps working.
 */
import { normalizeHandle } from './handle';
import type { AccessMode, ShelfAccess } from './access';

// Project defaults. Both values are PUBLIC by design (the anon key only works through row-level security).
// A build can override them with VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY. Never put a service_role key here.
const DEFAULT_URL = 'https://puvcorlkdxerphfdzpsz.supabase.co';
const DEFAULT_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB1dmNvcmxrZHhlcnBoZmR6cHN6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUzNDA5NTgsImV4cCI6MjExMDkxNjk1OH0.oEzs4Kk4dHH1hECU-6MytAUm4mOWRgWdatVfNWe9sgs';

/** accepts the URL with or without a trailing slash or the /rest/v1 suffix */
export const cleanBaseUrl = (u: string) => u.trim().replace(/\/+$/, '').replace(/\/rest\/v1$/, '').replace(/\/+$/, '');

const URL_BASE = cleanBaseUrl((import.meta.env.VITE_SUPABASE_URL as string | undefined) || DEFAULT_URL);
const ANON_KEY = ((import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) || DEFAULT_ANON_KEY).trim();
const KEY = 'margins.sb';

/** false when the build was made without a Supabase project: the UI says so instead of pretending */
export const onlineConfigured = !!URL_BASE && !!ANON_KEY;

export type OnlineErrorCode =
  | 'notConfigured' | 'offline' | 'notSignedIn' | 'sessionExpired' | 'handleTaken' | 'handleInvalid' | 'handleReserved'
  | 'handleCooldown' | 'alreadyHasProfile' | 'rateLimited' | 'quota' | 'passwordInvalid' | 'notFound' | 'duplicate' | 'tooLarge' | 'uploadFailed'
  | 'profileRequired' | 'fileUnavailable' | 'cancelled' | 'unknown';

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
  const b = (body ?? {}) as { code?: string; message?: string; error_description?: string; msg?: string; statusCode?: string | number };
  const msg = String(b.message ?? b.error_description ?? b.msg ?? '');
  const code = String(b.code ?? '');
  if (/handle_reserved/.test(msg)) return new OnlineError('handleReserved', msg);
  if (/handle_cooldown/.test(msg)) return new OnlineError('handleCooldown', msg);
  if (code === '23505' && /handle/.test(msg)) return new OnlineError('handleTaken', msg);
  if (code === '23505' && /profiles_pkey/.test(msg)) return new OnlineError('alreadyHasProfile', msg);
  if (code === '23514' && /handle/.test(msg)) return new OnlineError('handleInvalid', msg);
  if (code === '23505' && /books_owner_id_file_hash/.test(msg)) return new OnlineError('duplicate', msg);
  if (status === 413 || String(b.statusCode ?? '') === '413' || /exceeded the maximum allowed size/i.test(msg)) return new OnlineError('tooLarge', msg);
  // a password grant needs the visitor's own profile (access_grants.user_id references profiles)
  if (code === '23503' && /access_grants/.test(msg)) return new OnlineError('profileRequired', msg);
  if (/upload_missing/.test(msg)) return new OnlineError('uploadFailed', msg);
  if (/password_invalid/.test(msg)) return new OnlineError('passwordInvalid', msg);
  if (/not_found/.test(msg)) return new OnlineError('notFound', msg);
  if (/rate_limited|cooldown/.test(msg) || status === 429) return new OnlineError('rateLimited', msg);
  if (/quota_exceeded/.test(msg) || code === '53400') return new OnlineError('quota', msg);
  if (status === 401 || /jwt|not_authenticated/i.test(msg) || code === '28000') return new OnlineError('sessionExpired', msg);
  return new OnlineError('unknown', msg || `HTTP ${status}`);
}

async function send(path: string, init: RequestInit & { json?: unknown } = {}, token?: string): Promise<unknown> {
  if (!onlineConfigured) throw new OnlineError('notConfigured');
  // Legacy anon keys are JWTs and may double as the bearer token. The newer `sb_publishable_...` keys are not JWTs:
  // they go in `apikey` only, and Authorization is sent only when there is a real user session token.
  const bearer = token ?? (ANON_KEY.startsWith('eyJ') ? ANON_KEY : undefined);
  const headers: Record<string, string> = { apikey: ANON_KEY, ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), ...(init.headers as Record<string, string>) };
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
  // stored files are not removed by the database cascade: delete them first (best effort, the account deletion still goes ahead)
  try {
    const mine = await listMyBooks();
    await removeBookFiles(mine);
  } catch {
    /* ignore */
  }
  await rpc('delete_my_account');
  writeSession(null);
}

/* ------------------------------------------------------------ library & shelves */
export interface OnlineLibrary {
  id: string;
  title: string;
  description: string;
  default_access: AccessMode;
}

export interface OnlineShelf {
  id: string;
  name: string;
  description: string;
  position: number;
  access: ShelfAccess;
}

const LIB_COLS = 'id,title,description,default_access';
const SHELF_COLS = 'id,name,description,position,access';
const mine = () => {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  return encodeURIComponent(uid);
};
const first = <T,>(rows: unknown): T => {
  const r = (rows as T[])?.[0];
  if (!r) throw new OnlineError('notFound');
  return r;
};

export async function fetchMyLibrary(): Promise<OnlineLibrary> {
  return first<OnlineLibrary>(await authed(`/rest/v1/libraries?owner_id=eq.${mine()}&select=${LIB_COLS}`));
}

export async function updateLibrary(id: string, patch: Partial<Pick<OnlineLibrary, 'title' | 'description' | 'default_access'>>): Promise<OnlineLibrary> {
  return first<OnlineLibrary>(
    await authed(`/rest/v1/libraries?id=eq.${encodeURIComponent(id)}&select=${LIB_COLS}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, json: patch }),
  );
}

export async function listMyShelves(): Promise<OnlineShelf[]> {
  return (await authed(`/rest/v1/shelves?owner_id=eq.${mine()}&select=${SHELF_COLS}&order=position.asc,created_at.asc`)) as OnlineShelf[];
}

export async function createShelf(libraryId: string, name: string, description: string, position: number): Promise<OnlineShelf> {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  return first<OnlineShelf>(
    await authed(`/rest/v1/shelves?select=${SHELF_COLS}`, {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      json: { library_id: libraryId, owner_id: uid, name: name.trim(), description: description.trim(), position },
    }),
  );
}

export async function updateShelf(id: string, patch: Partial<Pick<OnlineShelf, 'name' | 'description' | 'access'>>): Promise<OnlineShelf> {
  const body = { ...patch, ...(patch.name !== undefined ? { name: patch.name.trim() } : {}), ...(patch.description !== undefined ? { description: patch.description.trim() } : {}) };
  return first<OnlineShelf>(
    await authed(`/rest/v1/shelves?id=eq.${encodeURIComponent(id)}&select=${SHELF_COLS}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, json: body }),
  );
}

export async function deleteShelf(id: string): Promise<void> {
  await authed(`/rest/v1/shelves?id=eq.${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export async function reorderShelves(ids: string[]): Promise<void> {
  await rpc('reorder_shelves', { p_ids: ids });
}

/* --------------------------------------------------------- password protection */
export type ProtectedType = 'library' | 'shelf' | 'book';

export async function hasAccessPassword(type: ProtectedType, id: string): Promise<boolean> {
  return (await rpc('has_access_password', { p_type: type, p_id: id })) === true;
}
export async function setAccessPassword(type: ProtectedType, id: string, password: string): Promise<void> {
  await rpc('set_access_password', { p_type: type, p_id: id, p_password: password });
}
export async function removeAccessPassword(type: ProtectedType, id: string): Promise<void> {
  await rpc('remove_access_password', { p_type: type, p_id: id });
}
export async function revokeAccessGrants(type: ProtectedType, id: string): Promise<void> {
  await rpc('revoke_access_grants', { p_type: type, p_id: id });
}

/* ------------------------------------------------------------------- books */
export interface OnlineBook {
  id: string;
  title: string;
  author: string;
  description: string;
  language: string | null;
  format: 'epub' | 'pdf';
  file_size: number;
  /** only the backend sets 'ready' (stage 3); until then nobody but the owner can see the book */
  file_status: 'pending' | 'ready' | 'failed';
  access: ShelfAccess;
  read_allowed: boolean;
  download_allowed: boolean;
}
export interface ShelfLink {
  shelf_id: string;
  book_id: string;
  position: number;
}

const BOOK_COLS = 'id,title,author,description,language,format,file_size,file_status,access,read_allowed,download_allowed';

export async function listMyBooks(): Promise<OnlineBook[]> {
  return (await authed(`/rest/v1/books?owner_id=eq.${mine()}&select=${BOOK_COLS}&order=created_at.desc`)) as OnlineBook[];
}

/** Creates the online record of a book (metadata only; the file itself is uploaded in stage 3). The owner confirms they may share it. */
export async function createBookRecord(b: { title: string; author?: string; language?: string; format: 'epub' | 'pdf'; hash: string; size: number }): Promise<OnlineBook> {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  return first<OnlineBook>(
    await authed(`/rest/v1/books?select=${BOOK_COLS}`, {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      json: {
        owner_id: uid,
        title: b.title.trim().slice(0, 300) || '—',
        author: (b.author ?? '').trim().slice(0, 300),
        language: b.language || null,
        format: b.format,
        file_hash: b.hash,
        file_size: b.size,
        rights_confirmed_at: new Date().toISOString(),
      },
    }),
  );
}

export type BookPatch = Partial<Pick<OnlineBook, 'title' | 'author' | 'description' | 'access' | 'read_allowed' | 'download_allowed'>> & { has_cover?: boolean };
export async function updateBook(id: string, patch: BookPatch): Promise<OnlineBook> {
  return first<OnlineBook>(
    await authed(`/rest/v1/books?id=eq.${encodeURIComponent(id)}&select=${BOOK_COLS}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, json: patch }),
  );
}
export async function deleteBook(id: string, format?: 'epub' | 'pdf'): Promise<void> {
  if (format) await removeBookFiles([{ id, format }]).catch(() => undefined);
  await authed(`/rest/v1/books?id=eq.${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export async function listMyShelfLinks(): Promise<ShelfLink[]> {
  return (await authed(`/rest/v1/shelf_books?owner_id=eq.${mine()}&select=shelf_id,book_id,position&order=position.asc`)) as ShelfLink[];
}
export async function addBookToShelf(shelfId: string, bookId: string, position: number): Promise<ShelfLink> {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  return first<ShelfLink>(
    await authed('/rest/v1/shelf_books?select=shelf_id,book_id,position', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      json: { shelf_id: shelfId, book_id: bookId, owner_id: uid, position },
    }),
  );
}
export async function removeBookFromShelf(shelfId: string, bookId: string): Promise<void> {
  await authed(`/rest/v1/shelf_books?shelf_id=eq.${encodeURIComponent(shelfId)}&book_id=eq.${encodeURIComponent(bookId)}`, { method: 'DELETE' });
}
export async function setShelfBookPosition(shelfId: string, bookId: string, position: number): Promise<void> {
  await authed(`/rest/v1/shelf_books?shelf_id=eq.${encodeURIComponent(shelfId)}&book_id=eq.${encodeURIComponent(bookId)}`, { method: 'PATCH', json: { position } });
}

/* ------------------------------------------------------------ file upload (stage 3a) */
/** Supabase free-plan ceiling per file; the `books` bucket enforces the same limit */
export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

export async function getAccessToken(): Promise<string> {
  return token();
}
const objectPath = (id: string, ext: string) => {
  const uid = sessionUserId();
  if (!uid) throw new OnlineError('notSignedIn');
  return `${uid}/${id}.${ext}`;
};

function xhrPut(url: string, headers: Record<string, string>, blob: Blob, onProgress: (f: number) => void): Promise<{ status: number; text: string }> {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open('POST', url);
    for (const [k, v] of Object.entries(headers)) x.setRequestHeader(k, v);
    x.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
    x.onload = () => resolve({ status: x.status, text: x.responseText });
    x.onerror = () => reject(new OnlineError('offline'));
    x.send(blob);
  });
}

/** uploads one object to a private bucket (the storage policy only accepts <uid>/<book id>.<ext> of a book the user owns) */
export async function uploadObject(bucket: 'books' | 'covers', path: string, blob: Blob, contentType: string, onProgress?: (fraction: number) => void): Promise<void> {
  if (!onlineConfigured) throw new OnlineError('notConfigured');
  const attempt = async (tok: string) => {
    const headers = { apikey: ANON_KEY, Authorization: `Bearer ${tok}`, 'Content-Type': contentType, 'x-upsert': 'true', 'cache-control': 'max-age=3600' };
    const url = `${URL_BASE}/storage/v1/object/${bucket}/${path}`;
    if (onProgress && typeof XMLHttpRequest !== 'undefined') return xhrPut(url, headers, blob, onProgress);
    try {
      const r = await fetch(url, { method: 'POST', headers, body: blob });
      return { status: r.status, text: await r.text() };
    } catch {
      throw new OnlineError('offline');
    }
  };
  let r = await attempt(await token());
  if (r.status === 401 && readSession()) r = await attempt((await refresh(readSession()!)).access_token);
  if (r.status < 200 || r.status >= 300) {
    let body: unknown = null;
    try { body = JSON.parse(r.text); } catch { /* not JSON */ }
    const e = mapError(r.status, body);
    throw e.code === 'unknown' ? new OnlineError('uploadFailed', e.message) : e;
  }
}

export async function removeBookFiles(books: { id: string; format: 'epub' | 'pdf' }[]): Promise<void> {
  if (books.length === 0) return;
  await authed('/storage/v1/object/books', { method: 'DELETE', json: { prefixes: books.map((b) => objectPath(b.id, b.format)) } });
  await authed('/storage/v1/object/covers', { method: 'DELETE', json: { prefixes: books.map((b) => objectPath(b.id, 'jpg')) } }).catch(() => undefined);
}

/** online book id -> sha-256 of its file, so any device can find the matching local file */
export async function myBookHashes(): Promise<Map<string, string>> {
  const rows = (await rpc('my_book_hashes')) as { id: string; file_hash: string }[];
  return new Map(rows.map((r) => [r.id, r.file_hash]));
}

export async function finalizeBookUpload(id: string): Promise<'pending' | 'ready' | 'failed'> {
  return (await rpc('finalize_book_upload', { p_book: id })) as 'pending' | 'ready' | 'failed';
}

/** uploads the file (and cover), then asks the database to verify it: resolves only when the book is ready */
export async function publishBookFile(book: Pick<OnlineBook, 'id' | 'format' | 'file_size'>, file: Blob, cover: Blob | undefined, onProgress?: (fraction: number) => void): Promise<void> {
  if (file.size > MAX_UPLOAD_BYTES) throw new OnlineError('tooLarge');
  if (file.size !== book.file_size) throw new OnlineError('uploadFailed', 'size_mismatch');
  await uploadObject('books', objectPath(book.id, book.format), file, book.format === 'pdf' ? 'application/pdf' : 'application/epub+zip', onProgress);
  if (cover) {
    try {
      await uploadObject('covers', objectPath(book.id, 'jpg'), cover, 'image/jpeg');
      await updateBook(book.id, { has_cover: true });
    } catch {
      /* a missing cover never blocks publishing the book */
    }
  }
  if ((await finalizeBookUpload(book.id)) !== 'ready') throw new OnlineError('uploadFailed', 'verification_failed');
}

/* ============================================================ visiting (stage 3b) */
export type VisitState = 'open' | 'locked' | 'unavailable';
export interface VisitShelf {
  id: string;
  state: 'open' | 'locked';
  /** only when open: a locked shelf reveals nothing about itself */
  name?: string;
  description?: string;
  position: number;
}
export interface VisitResult {
  profile: OnlineProfile;
  library: { id: string; state: VisitState; title?: string; description?: string };
  shelves: VisitShelf[];
  /** books with their own password that are not unlocked yet (ids only) */
  locked_books: { id: string }[];
}
/** a book of somebody else, as far as the database lets this visitor see it */
export interface VisitedBook {
  id: string;
  owner_id: string;
  title: string;
  author: string;
  description: string;
  language: string | null;
  format: 'epub' | 'pdf';
  file_size: number;
  file_status: 'pending' | 'ready' | 'failed';
  has_cover: boolean;
  read_allowed: boolean;
  download_allowed: boolean;
}

/** signed-out visitors may open public libraries (the anon key); a signed-in visitor always uses her own session */
const maybeAuthed = (path: string, init: RequestInit & { json?: unknown } = {}) => (hasSession() ? authed(path, init) : send(path, init));

/** Opens a library by @handle. Unknown and blocked look the same (notFound). */
export async function visitLibrary(handle: string): Promise<VisitResult> {
  const h = normalizeHandle(handle);
  if (!h) throw new OnlineError('notFound');
  const r = (await maybeAuthed('/rest/v1/rpc/visit_library', { method: 'POST', json: { p_handle: h } })) as VisitResult | null;
  if (!r?.profile || !r.library) throw new OnlineError('notFound');
  return { ...r, shelves: r.shelves ?? [], locked_books: r.locked_books ?? [] };
}

const VISIT_COLS = 'id,owner_id,title,author,description,language,format,file_size,file_status,has_cover,read_allowed,download_allowed';
const PAGE = 1000;

/** every book of `ownerId` that row-level security lets this visitor see (ready books only) */
export async function listVisitedBooks(ownerId: string): Promise<VisitedBook[]> {
  const out: VisitedBook[] = [];
  for (let offset = 0; offset < 4000; offset += PAGE) {
    const rows = (await maybeAuthed(
      `/rest/v1/books?owner_id=eq.${encodeURIComponent(ownerId)}&select=${VISIT_COLS}&order=created_at.desc&limit=${PAGE}&offset=${offset}`,
    )) as VisitedBook[];
    out.push(...rows);
    if (rows.length < PAGE) break;
  }
  // the owner looking at her own library also receives unfinished uploads: nobody else ever does
  return out.filter((b) => b.file_status === 'ready');
}

export async function listVisitedShelfLinks(ownerId: string): Promise<ShelfLink[]> {
  const out: ShelfLink[] = [];
  for (let offset = 0; offset < 4000; offset += PAGE) {
    const rows = (await maybeAuthed(
      `/rest/v1/shelf_books?owner_id=eq.${encodeURIComponent(ownerId)}&select=shelf_id,book_id,position&order=position.asc&limit=${PAGE}&offset=${offset}`,
    )) as ShelfLink[];
    out.push(...rows);
    if (rows.length < PAGE) break;
  }
  return out;
}

/** true = unlocked for 24 hours. A wrong password and an unknown resource look the same. */
export async function redeemPassword(type: ProtectedType, id: string, password: string): Promise<boolean> {
  return (await rpc('redeem_access_password', { p_type: type, p_id: id, p_password: password })) === true;
}

/**
 * Fetches a stored file with the visitor's own session token. The storage policy re-checks, on EVERY request,
 * that she may read / download this book, so there is no link that could be forwarded or reused later
 * (the reason this does not use long-lived signed URLs). Resolves only with a file of the size the owner declared.
 */
export async function fetchStoredFile(
  bucket: 'books' | 'covers',
  ownerId: string,
  bookId: string,
  ext: 'epub' | 'pdf' | 'jpg',
  opts: { expectedSize?: number; onProgress?: (fraction: number) => void; signal?: AbortSignal } = {},
): Promise<Blob> {
  if (!onlineConfigured) throw new OnlineError('notConfigured');
  const url = `${URL_BASE}/storage/v1/object/authenticated/${bucket}/${encodeURIComponent(ownerId)}/${encodeURIComponent(bookId)}.${ext}`;
  const attempt = async (tok: string): Promise<Response> => {
    try {
      return await fetch(url, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${tok}` }, signal: opts.signal });
    } catch {
      throw new OnlineError(opts.signal?.aborted ? 'cancelled' : 'offline');
    }
  };
  let res = await attempt(await token());
  if (res.status === 401 && readSession()) res = await attempt((await refresh(readSession()!)).access_token);
  if (!res.ok) throw res.status === 429 ? new OnlineError('rateLimited') : res.status >= 500 ? new OnlineError('unknown', `HTTP ${res.status}`) : new OnlineError('fileUnavailable');
  let blob: Blob;
  const total = Number(res.headers?.get?.('content-length')) || opts.expectedSize || 0;
  if (opts.onProgress && res.body && typeof res.body.getReader === 'function' && total > 0) {
    const reader = res.body.getReader();
    const chunks: Uint8Array[] = [];
    let got = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        got += value.byteLength;
        opts.onProgress(Math.min(1, got / total));
      }
    } catch {
      throw new OnlineError(opts.signal?.aborted ? 'cancelled' : 'offline');
    }
    blob = new Blob(chunks as BlobPart[]);
  } else {
    blob = await res.blob();
  }
  if (opts.expectedSize !== undefined && blob.size !== opts.expectedSize) throw new OnlineError('fileUnavailable', 'size_mismatch');
  return blob;
}

export const downloadBookFile = (b: Pick<VisitedBook, 'id' | 'owner_id' | 'format' | 'file_size'>, onProgress?: (f: number) => void, signal?: AbortSignal) =>
  fetchStoredFile('books', b.owner_id, b.id, b.format, { expectedSize: b.file_size, onProgress, signal });

/* covers: fetched lazily, a few at a time, kept for the session */
const coverCache = new Map<string, Promise<Blob | null>>();
let coverActive = 0;
const coverQueue: (() => void)[] = [];
const coverSlot = () => new Promise<void>((go) => (coverActive < 4 ? (coverActive++, go()) : coverQueue.push(() => (coverActive++, go()))));
const coverFree = () => { coverActive--; coverQueue.shift()?.(); };

export function fetchCover(ownerId: string, bookId: string): Promise<Blob | null> {
  const key = `${ownerId}/${bookId}`;
  let p = coverCache.get(key);
  if (!p) {
    p = (async () => {
      await coverSlot();
      try {
        return await fetchStoredFile('covers', ownerId, bookId, 'jpg');
      } catch {
        coverCache.delete(key); // retry next time (offline, expired session...)
        return null; // a missing cover is never an error
      } finally {
        coverFree();
      }
    })();
    coverCache.set(key, p);
  }
  return p;
}
export const clearCoverCache = () => coverCache.clear();
