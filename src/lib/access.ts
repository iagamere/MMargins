/** Access modes of the online library. Same ordering as the database (private > friends > password > public). */
export type AccessMode = 'public' | 'password' | 'friends' | 'private';
export type ShelfAccess = AccessMode | 'inherit';

export const ACCESS_MODES: AccessMode[] = ['public', 'password', 'friends', 'private'];
const STRICTNESS: Record<AccessMode, number> = { public: 1, password: 2, friends: 3, private: 4 };

/** the mode a shelf really has: its own, or the library default when it inherits */
export const effectiveShelfMode = (shelf: ShelfAccess, libraryDefault: AccessMode): AccessMode => (shelf === 'inherit' ? libraryDefault : shelf);

/** true when moving from `from` to `to` lets MORE people in (needs an explicit confirmation) */
export const isLoosening = (from: AccessMode, to: AccessMode) => STRICTNESS[to] < STRICTNESS[from];

/** the mode a book really has: its own, else the strictest of its shelves, else the library default */
export const effectiveBookMode = (book: ShelfAccess, shelfModes: AccessMode[], libraryDefault: AccessMode): AccessMode => {
  if (book !== 'inherit') return book;
  if (shelfModes.length === 0) return libraryDefault;
  return shelfModes.reduce((a, b) => (STRICTNESS[b] > STRICTNESS[a] ? b : a));
};
