import { useEffect, useState } from 'react';
import { ChevronDown, ChevronUp, X } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { getFile } from '../lib/db';
import { effectiveBookMode, effectiveShelfMode, isLoosening, type AccessMode, type ShelfAccess } from '../lib/access';
import {
  MAX_UPLOAD_BYTES, OnlineError, addBookToShelf, createBookRecord, deleteBook, hasAccessPassword, removeBookFromShelf, setAccessPassword, setShelfBookPosition, updateBook,
  type OnlineBook, type OnlineLibrary, type OnlineShelf, type ShelfLink,
} from '../lib/online';
import type { BookRecord } from '../lib/types';
import { Sheet } from './Sheet';
import { ConfirmDialog } from './ConfirmDialog';
import { AccessBadge, AccessPicker, PasswordBlock, PublicConfirm, codeOf } from './AccessControls';

const HEX64 = /^[0-9a-f]{64}$/;

/** the book's real sha-256: the stored one when valid, else recomputed from the file on this device */
async function sha256Of(b: BookRecord): Promise<string> {
  if (HEX64.test(b.hash)) return b.hash;
  const blob = await getFile(b.id);
  if (!blob || !crypto?.subtle) throw new OnlineError('unknown');
  const d = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

export const shelfModesOf = (bookId: string, links: ShelfLink[], shelves: OnlineShelf[], lib: OnlineLibrary): AccessMode[] =>
  links.filter((l) => l.book_id === bookId).flatMap((l) => {
    const s = shelves.find((x) => x.id === l.shelf_id);
    return s ? [effectiveShelfMode(s.access, lib.default_access)] : [];
  });

/* ----------------------------------------------------- add books from this device */
export function AddBooksSheet({ onClose, onAdded }: { onClose: () => void; onAdded: (b: OnlineBook) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const local = useApp((s) => s.books).filter((b) => !b.tempRead);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [rights, setRights] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const toggle = (id: string) => setPicked((p) => { const n = new Set(p); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const add = async () => {
    setBusy(true);
    setErr(null);
    let added = 0;
    let dup = 0;
    try {
      for (const b of local.filter((x) => picked.has(x.id))) {
        try {
          const rec = await createBookRecord({ title: b.title, author: b.author, language: b.language, format: b.format, hash: await sha256Of(b), size: b.size });
          onAdded(rec);
          added++;
        } catch (e) {
          if (codeOf(e) === 'duplicate') dup++;
          else throw e;
        }
      }
      if (added) toast('onlineBooks.added', 'success', { count: added });
      else if (dup) toast('online.err.duplicate', 'info');
      onClose();
    } catch (e) {
      setErr(codeOf(e));
      if (added) toast('onlineBooks.added', 'success', { count: added });
    } finally {
      setBusy(false);
    }
  };
  return (
    <Sheet title={t('onlineBooks.addTitle')} onClose={onClose}>
      <div className="online-form">
        <p className="hint">{t('onlineBooks.addHint')}</p>
        {local.length === 0 ? <p className="hint">{t('onlineBooks.noLocal')}</p> : (
          <ul className="olib-list">
            {local.map((b) => (
              <li key={b.id} className="olib-row">
                <label className="olib-check">
                  <input type="checkbox" checked={picked.has(b.id)} disabled={b.size > MAX_UPLOAD_BYTES} onChange={() => toggle(b.id)} />
                  <span className="olib-main"><span className="label" dir="auto">{b.title}</span>{b.author && <span className="hint" dir="auto">{b.author}</span>}{b.size > MAX_UPLOAD_BYTES && <span className="hint">{t('onlineBooks.tooLarge')}</span>}</span>
                </label>
              </li>
            ))}
          </ul>
        )}
        <label className="olib-check">
          <input type="checkbox" checked={rights} onChange={(e) => setRights(e.target.checked)} />
          <span>{t('onlineBooks.rights')}</span>
        </label>
        {err && <p className="acc-error" role="alert">{t(`online.err.${err}`)}</p>}
        <div className="acc-actions">
          <button className="btn btn-primary" disabled={busy || !rights || picked.size === 0} onClick={() => void add()}>{busy ? '…' : t('onlineBooks.add', { count: picked.size })}</button>
          <button className="btn btn-ghost" onClick={onClose}>{t('common.cancel')}</button>
        </div>
      </div>
    </Sheet>
  );
}

/* ------------------------------------------------------------- one book's settings */
export function BookSheet({ book, lib, shelves, links, onClose, onSaved, onDeleted }: { book: OnlineBook; lib: OnlineLibrary; shelves: OnlineShelf[]; links: ShelfLink[]; onClose: () => void; onSaved: (b: OnlineBook) => void; onDeleted: (id: string) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [title, setTitle] = useState(book.title);
  const [author, setAuthor] = useState(book.author);
  const [desc, setDesc] = useState(book.description);
  const [access, setAccess] = useState<ShelfAccess>(book.access);
  const [read, setRead] = useState(book.read_allowed);
  const [dl, setDl] = useState(book.download_allowed);
  const [pw, setPw] = useState('');
  const [has, setHas] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [confirmPublic, setConfirmPublic] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  useEffect(() => {
    let alive = true;
    hasAccessPassword('book', book.id).then((h) => alive && setHas(h), () => alive && setHas(null));
    return () => { alive = false; };
  }, [book.id]);

  const modes = shelfModesOf(book.id, links, shelves, lib);
  const before = effectiveBookMode(book.access, modes, lib.default_access);
  const after = effectiveBookMode(access, modes, lib.default_access);
  const own = access === 'password';
  const needsPw = own && has === false && pw.length === 0;
  const pwBad = pw.length > 0 && pw.length < 8;
  const ok = title.trim().length > 0 && !needsPw && !pwBad && !busy;

  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (own && pw) await setAccessPassword('book', book.id, pw);
      const next = await updateBook(book.id, { title: title.trim(), author: author.trim(), description: desc.trim(), access, read_allowed: read, download_allowed: dl });
      onSaved(next);
      toast('onlineLib.saved', 'success');
      onClose();
    } catch (e) {
      setErr(codeOf(e));
    } finally {
      setBusy(false);
    }
  };
  const submit = () => (after === 'public' && isLoosening(before, 'public') ? setConfirmPublic(true) : void save());

  return (
    <Sheet title={t('onlineBooks.edit')} onClose={onClose}>
      <form className="online-form" onSubmit={(e) => { e.preventDefault(); if (ok) submit(); }}>
        {book.file_status !== 'ready' && <p className="hint olib-note">{t('onlineBooks.pending')}</p>}
        <div>
          <label className="online-label" htmlFor="bk-title">{t('onlineBooks.bookTitle')}</label>
          <input id="bk-title" className="name-input" style={{ width: '100%' }} dir="auto" maxLength={300} value={title} onChange={(e) => setTitle(e.target.value)} />
        </div>
        <div>
          <label className="online-label" htmlFor="bk-author">{t('onlineBooks.author')}</label>
          <input id="bk-author" className="name-input" style={{ width: '100%' }} dir="auto" maxLength={300} value={author} onChange={(e) => setAuthor(e.target.value)} />
        </div>
        <div>
          <label className="online-label" htmlFor="bk-desc">{t('onlineLib.description')}</label>
          <textarea id="bk-desc" className="textarea" dir="auto" maxLength={4000} value={desc} onChange={(e) => setDesc(e.target.value)} />
        </div>
        <AccessPicker label={t('onlineBooks.access')} allowInherit inheritKey="onlineBooks.inheritDesc" value={access} onChange={setAccess} />
        <p className="hint">{t('onlineBooks.effective')} <AccessBadge mode={after} inherited={access === 'inherit'} /></p>
        {own && <PasswordBlock type="book" id={book.id} mode={access} value={pw} onChange={setPw} has={has} setHas={setHas} />}
        <fieldset className="olib-picker">
          <legend className="online-label">{t('onlineBooks.permissions')}</legend>
          <label className="olib-check"><input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} /><span>{t('onlineBooks.allowRead')}</span></label>
          <label className="olib-check"><input type="checkbox" checked={dl} onChange={(e) => setDl(e.target.checked)} /><span>{t('onlineBooks.allowDownload')}</span></label>
          <p className="hint">{t('onlineBooks.permHint')}</p>
        </fieldset>
        {err && <p className="acc-error" role="alert">{t(`online.err.${err}`)}</p>}
        <div className="acc-actions">
          <button className="btn btn-primary" type="submit" disabled={!ok}>{busy ? '…' : t('online.save')}</button>
          <button className="btn btn-ghost" type="button" onClick={onClose}>{t('common.cancel')}</button>
          <button className="btn btn-ghost btn-danger" type="button" onClick={() => setConfirmDelete(true)}>{t('onlineBooks.remove')}</button>
        </div>
      </form>
      {confirmPublic && <PublicConfirm onCancel={() => setConfirmPublic(false)} onConfirm={() => { setConfirmPublic(false); void save(); }} />}
      {confirmDelete && (
        <ConfirmDialog danger title={t('onlineBooks.removeTitle')} body={t('onlineBooks.removeBody')} confirmLabel={t('onlineBooks.remove')} onCancel={() => setConfirmDelete(false)}
          onConfirm={async () => {
            setConfirmDelete(false);
            try { await deleteBook(book.id, book.format); onDeleted(book.id); toast('onlineBooks.removed', 'info'); onClose(); } catch (e) { setErr(codeOf(e)); }
          }} />
      )}
    </Sheet>
  );
}

/* ------------------------------------------------------------ books inside a shelf */
export function ShelfBooksSheet({ shelf, books, links, onClose, onLinks }: { shelf: OnlineShelf; books: OnlineBook[]; links: ShelfLink[]; onClose: () => void; onLinks: (next: ShelfLink[]) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [busy, setBusy] = useState(false);
  const mine = links.filter((l) => l.shelf_id === shelf.id).sort((a, b) => a.position - b.position);
  const inShelf = mine.map((l) => books.find((b) => b.id === l.book_id)).filter((b): b is OnlineBook => !!b);
  const free = books.filter((b) => !mine.some((l) => l.book_id === b.id));
  const others = links.filter((l) => l.shelf_id !== shelf.id);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); } catch (e) { toast(`online.err.${codeOf(e)}`, 'error'); } finally { setBusy(false); }
  };
  const add = (id: string) => run(async () => {
    const pos = mine.reduce((m, l) => Math.max(m, l.position), -1) + 1;
    const l = await addBookToShelf(shelf.id, id, pos);
    onLinks([...links, l]);
  });
  const del = (id: string) => run(async () => {
    await removeBookFromShelf(shelf.id, id);
    onLinks(links.filter((l) => !(l.shelf_id === shelf.id && l.book_id === id)));
  });
  const move = (i: number, dir: -1 | 1) => run(async () => {
    const j = i + dir;
    if (j < 0 || j >= mine.length) return;
    const order = mine.map((l) => l.book_id);
    [order[i], order[j]] = [order[j], order[i]];
    // positions are rewritten as 0..n-1 so they stay distinct; only changed rows are sent
    const next = order.map((book_id, k) => ({ shelf_id: shelf.id, book_id, position: k }));
    for (const n of next) if (mine.find((l) => l.book_id === n.book_id)?.position !== n.position) await setShelfBookPosition(shelf.id, n.book_id, n.position);
    onLinks([...others, ...next]);
  });

  return (
    <Sheet title={`${t('onlineBooks.shelfBooks')} — ${shelf.name}`} onClose={onClose}>
      <div className="online-form">
        {inShelf.length === 0 ? <p className="hint">{t('onlineBooks.shelfEmpty')}</p> : (
          <ul className="olib-list">
            {inShelf.map((b, i) => (
              <li key={b.id} className="olib-row">
                <div className="olib-main"><div className="label" dir="auto">{b.title}</div>{b.author && <div className="hint" dir="auto">{b.author}</div>}</div>
                <div className="olib-tools">
                  <button className="icon-btn" disabled={busy || i === 0} onClick={() => void move(i, -1)} aria-label={t('onlineLib.moveUp')}><ChevronUp size={20} /></button>
                  <button className="icon-btn" disabled={busy || i === inShelf.length - 1} onClick={() => void move(i, 1)} aria-label={t('onlineLib.moveDown')}><ChevronDown size={20} /></button>
                  <button className="icon-btn" disabled={busy} onClick={() => void del(b.id)} aria-label={t('onlineBooks.takeOut')}><X size={18} /></button>
                </div>
              </li>
            ))}
          </ul>
        )}
        <h3 className="online-label">{t('onlineBooks.addToShelf')}</h3>
        {free.length === 0 ? <p className="hint">{t('onlineBooks.nothingToAdd')}</p> : (
          <ul className="olib-list">
            {free.map((b) => (
              <li key={b.id} className="olib-row">
                <div className="olib-main"><div className="label" dir="auto">{b.title}</div></div>
                <button className="btn btn-sm" disabled={busy} onClick={() => void add(b.id)}>{t('onlineBooks.put')}</button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Sheet>
  );
}
