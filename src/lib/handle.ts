/** Public @handle rules. The database enforces the same rules (profiles_handle_format + reserved_handles);
 *  this copy only gives instant feedback while typing. */
export const RESERVED_HANDLES = [
  'admin', 'administrator', 'root', 'support', 'help', 'margins', 'margin', 'moderator', 'mod', 'official', 'security',
  'staff', 'system', 'null', 'undefined', 'anonymous', 'me', 'you', 'api', 'www', 'settings', 'account', 'library',
  'shelf', 'book', 'discover',
];

export type HandleProblem = 'empty' | 'short' | 'long' | 'chars' | 'edges' | 'repeat' | 'reserved';

export const normalizeHandle = (h: string) => h.trim().replace(/^@/, '').toLowerCase();

/** null = looks valid */
export function handleProblem(raw: string): HandleProblem | null {
  const h = normalizeHandle(raw);
  if (!h) return 'empty';
  if (h.length < 3) return 'short';
  if (h.length > 30) return 'long';
  if (!/^[a-z0-9_.]+$/.test(h)) return 'chars';
  if (!/^[a-z0-9]/.test(h) || !/[a-z0-9]$/.test(h)) return 'edges';
  if (/[_.]{2}/.test(h)) return 'repeat';
  if (RESERVED_HANDLES.includes(h)) return 'reserved';
  return null;
}
