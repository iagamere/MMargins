/**
 * Stage 3b: what a visitor can do with somebody else's published book.
 *   read    -> a temporary copy opens in the reader and is deleted when the reader closes (needs read_allowed)
 *   import  -> the file joins the visitor's own local library (needs download_allowed)
 * The database decides who may do what (storage policy); the checks here only choose which buttons to show
 * and stop obviously impossible requests early. A read-only book is NOT technically copy-proof: whoever can
 * read the bytes could save them, so "read only" is an honest courtesy of the owner, not DRM (see docs).
 */
import { useApp } from '../store/useApp';
import { importFile } from './importer';
import { patchBook } from './db';
import { OnlineError, downloadBookFile, type VisitedBook } from './online';
import type { BookRecord } from './types';

export type VisitAction = 'read' | 'import';

const fileOf = (blob: Blob, b: VisitedBook) => {
  const safe = (b.title || 'book').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || 'book';
  return new File([blob], `${safe}.${b.format}`, { type: b.format === 'pdf' ? 'application/pdf' : 'application/epub+zip' });
};

/** can this visitor perform the action? (the owner's switches; the database enforces them again) */
export const allowed = (b: Pick<VisitedBook, 'read_allowed' | 'download_allowed'>, a: VisitAction) => (a === 'read' ? b.read_allowed || b.download_allowed : b.download_allowed);

/**
 * Downloads the book and returns the id of a local book to open. `null` = failed (a toast was shown).
 * If the same file is already in the visitor's own library, that book is opened instead (no copy at all).
 */
export async function readVisited(b: VisitedBook, onProgress: (f: number) => void, signal?: AbortSignal): Promise<string | null> {
  const st = useApp.getState();
  try {
    const blob = await downloadBookFile(b, onProgress, signal);
    const res = await importFile(fileOf(blob, b));
    if (res.status === 'duplicate') {
      // a visitor copy that is still on disk (e.g. reopened within a moment): keep serving it to the reader
      if (res.book.visitor && useApp.getState().visitorBook?.id !== res.book.id) useApp.getState().setVisitorBook(res.book);
      return res.book.id;
    }
    if (res.status === 'error') {
      st.toast(`err.${res.code}`, 'error', { name: b.title });
      return null;
    }
    // a leftover copy from an earlier visit is replaced, never listed
    const prev = st.visitorBook;
    if (prev && prev.id !== res.book.id) await import('./cloud').then((m) => m.discardTempRead(prev.id));
    const rec: BookRecord = { ...res.book, visitor: true, title: res.book.title || b.title };
    await patchBook(rec.id, { visitor: true }).catch(() => undefined);
    useApp.getState().setVisitorBook(rec);
    return rec.id;
  } catch (e) {
    reportFail(e, b);
    return null;
  }
}

/** copies the file into the visitor's own library; resolves with the local book (new or already there) */
export async function importVisited(b: VisitedBook, onProgress: (f: number) => void, signal?: AbortSignal): Promise<BookRecord | null> {
  if (!b.download_allowed) return null;
  try {
    const blob = await downloadBookFile(b, onProgress, signal);
    return await useApp.getState().importFiles([fileOf(blob, b)]);
  } catch (e) {
    reportFail(e, b);
    return null;
  }
}

function reportFail(e: unknown, b: VisitedBook) {
  if (e instanceof OnlineError && e.code === 'cancelled') return;
  const code = e instanceof OnlineError ? e.code : 'unknown';
  useApp.getState().toast(`online.err.${code}`, 'error', { name: b.title });
}
