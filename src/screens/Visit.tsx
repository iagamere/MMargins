import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, BookOpen, Download, KeyRound, Lock, X } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { handleProblem, normalizeHandle } from '../lib/handle';
import { formatBytes } from '../lib/utils';
import {
  fetchCover, hasSession, listVisitedBooks, listVisitedShelfLinks, onlineConfigured, redeemPassword, visitLibrary,
  type ProtectedType, type ShelfLink, type VisitedBook, type VisitResult,
} from '../lib/online';
import { allowed, importVisited, readVisited } from '../lib/visit';
import { useOnline } from '../store/useOnline';
import { Sheet } from '../components/Sheet';
import { useObjectUrl } from '../components/BookCover';
import { codeOf } from '../components/AccessControls';

/* ----------------------------------------------------------------- open by @handle */
export function VisitSheet({ onClose }: { onClose: () => void }) {
  const { t } = useT();
  const navigate = useApp((s) => s.navigate);
  const [value, setValue] = useState('');
  const h = normalizeHandle(value);
  const bad = h.length > 0 && handleProblem(h) !== null && handleProblem(h) !== 'reserved';
  const go = () => {
    if (!h || bad) return;
    onClose();
    navigate({ name: 'visit', handle: h });
  };
  return (
    <Sheet title={t('visit.open')} onClose={onClose}>
      <form className="online-form" onSubmit={(e) => { e.preventDefault(); go(); }}>
        <p className="hint">{t('visit.sheetHint')}</p>
        <div>
          <label className="online-label" htmlFor="visit-handle">{t('online.handle')}</label>
          <input id="visit-handle" className="name-input" style={{ width: '100%' }} dir="ltr" autoCapitalize="none" autoCorrect="off" spellCheck={false} placeholder="@handle" value={value} maxLength={32} onChange={(e) => setValue(e.target.value)} autoFocus />
        </div>
        <div className="acc-actions">
          <button className="btn btn-primary" type="submit" disabled={!h || bad}>{t('visit.go')}</button>
          <button className="btn btn-ghost" type="button" onClick={onClose}>{t('common.cancel')}</button>
        </div>
      </form>
    </Sheet>
  );
}

/* ------------------------------------------------------------------ password prompt */
function UnlockSheet({ type, id, onClose, onUnlocked }: { type: ProtectedType; id: string; onClose: () => void; onUnlocked: () => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const submit = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (await redeemPassword(type, id, pw)) {
        toast('visit.unlocked', 'success');
        onClose();
        onUnlocked();
      } else {
        setErr('visit.wrongPassword');
      }
    } catch (e) {
      setErr(`online.err.${codeOf(e)}`);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Sheet title={t('visit.unlock')} onClose={onClose}>
      <form className="online-form" onSubmit={(e) => { e.preventDefault(); if (pw && !busy) void submit(); }}>
        <div>
          <label className="online-label" htmlFor="visit-pw">{t('visit.password')}</label>
          <input id="visit-pw" className="name-input" style={{ width: '100%' }} type="password" autoComplete="off" maxLength={128} value={pw} onChange={(e) => setPw(e.target.value)} autoFocus />
        </div>
        {err && <p className="acc-error" role="alert">{t(err)}</p>}
        <div className="acc-actions">
          <button className="btn btn-primary" type="submit" disabled={!pw || busy}>{busy ? '…' : t('visit.unlock')}</button>
          <button className="btn btn-ghost" type="button" onClick={onClose}>{t('common.cancel')}</button>
        </div>
      </form>
    </Sheet>
  );
}

/* --------------------------------------------------------------------- one book */
function VisitedCover({ book }: { book: VisitedBook }) {
  const [blob, setBlob] = useState<Blob | undefined>();
  useEffect(() => {
    let alive = true;
    if (book.has_cover && hasSession()) void fetchCover(book.owner_id, book.id).then((b) => alive && b && setBlob(b));
    return () => { alive = false; };
  }, [book.id, book.owner_id, book.has_cover]);
  const url = useObjectUrl(blob);
  return (
    <div className="visit-cover" aria-hidden="true">
      {url ? <img src={url} alt="" draggable={false} /> : <span>{book.format.toUpperCase()}</span>}
    </div>
  );
}

export function VisitedRow({ book, owner }: { book: VisitedBook; owner?: string }) {
  const { t, n } = useT();
  const navigate = useApp((s) => s.navigate);
  const toast = useApp((s) => s.toast);
  const [pct, setPct] = useState<number | null>(null);
  const abort = useRef<AbortController | null>(null);
  const canRead = allowed(book, 'read');
  const canSave = allowed(book, 'import');
  const busy = pct !== null;

  const run = async (kind: 'read' | 'import') => {
    if (!hasSession()) return toast('online.err.notSignedIn', 'error');
    abort.current = new AbortController();
    setPct(0);
    try {
      if (kind === 'read') {
        const id = await readVisited(book, (f) => setPct(Math.round(f * 100)), abort.current.signal);
        if (id) navigate({ name: 'reader', id });
      } else {
        await importVisited(book, (f) => setPct(Math.round(f * 100)), abort.current.signal);
      }
    } finally {
      abort.current = null;
      setPct(null);
    }
  };
  useEffect(() => () => abort.current?.abort(), []);

  return (
    <li className="olib-row visit-row">
      <VisitedCover book={book} />
      <div className="olib-main">
        <div className="label" dir="auto">{book.title}</div>
        {book.author && <div className="hint olib-desc" dir="auto">{book.author}</div>}
        {owner && <div className="hint" dir="auto">{owner}</div>}
        <div className="hint">{book.format.toUpperCase()} · {formatBytes(book.file_size)}</div>
        {!canRead && !canSave && <div className="hint">{t('visit.listedOnly')}</div>}
        {canRead && !book.download_allowed && <div className="hint">{t('visit.readOnly')}</div>}
        {busy && <div className="hint" role="status">{t('visit.downloading', { pct: n(pct ?? 0) })}</div>}
      </div>
      <div className="olib-tools visit-tools">
        {busy ? (
          <button className="icon-btn" onClick={() => abort.current?.abort()} aria-label={t('common.cancel')}><X size={18} /></button>
        ) : (
          <>
            {canRead && <button className="btn btn-sm btn-primary" onClick={() => void run('read')}><BookOpen size={16} aria-hidden="true" />{t('visit.read')}</button>}
            {canSave && <button className="btn btn-sm" onClick={() => void run('import')}><Download size={16} aria-hidden="true" />{t('visit.save')}</button>}
          </>
        )}
      </div>
    </li>
  );
}

/* ------------------------------------------------------------------------ screen */
export function VisitScreen({ handle }: { handle: string }) {
  const { t } = useT();
  const navigate = useApp((s) => s.navigate);
  const back = useApp((s) => s.back);
  const me = useOnline((s) => s.profile);
  const [res, setRes] = useState<VisitResult | null>(null);
  const [books, setBooks] = useState<VisitedBook[]>([]);
  const [links, setLinks] = useState<ShelfLink[]>([]);
  const [load, setLoad] = useState<'loading' | 'ready' | 'error'>('loading');
  const [fail, setFail] = useState('unknown');
  const [unlock, setUnlock] = useState<{ type: ProtectedType; id: string } | null>(null);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };

  const reload = useCallback(async () => {
    setLoad('loading');
    try {
      const r = await visitLibrary(handle);
      setRes(r);
      if (r.library.state === 'open' || r.shelves.length || r.locked_books.length) {
        const [b, l] = await Promise.all([listVisitedBooks(r.profile.id), listVisitedShelfLinks(r.profile.id)]);
        setBooks(b);
        setLinks(l);
      } else {
        setBooks([]);
        setLinks([]);
      }
      setLoad('ready');
    } catch (e) {
      setFail(codeOf(e));
      setLoad('error');
    }
  }, [handle]);
  useEffect(() => { void reload(); }, [reload]);

  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (load === 'loading') body = <p className="hint" role="status">{t('visit.loading')}</p>;
  else if (load === 'error' || !res) {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${fail}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => void reload()}>{t('online.retry')}</button></div>
      </div>
    );
  } else {
    const lib = res.library;
    const byId = new Map(books.map((b) => [b.id, b]));
    const shelfOf = new Map<string, string[]>();
    for (const l of links) if (byId.has(l.book_id)) shelfOf.set(l.shelf_id, [...(shelfOf.get(l.shelf_id) ?? []), l.book_id]);
    const onShelf = new Set([...shelfOf.values()].flat());
    const openShelves = res.shelves.filter((s) => s.state === 'open');
    const lockedShelves = res.shelves.filter((s) => s.state === 'locked');
    const loose = books.filter((b) => !onShelf.has(b.id));
    const signedOut = !hasSession();
    const lockCard = (label: string, type: ProtectedType, id: string) => (
      <li key={id} className="olib-row">
        <div className="olib-main"><span className="olib-badge password"><Lock size={14} aria-hidden="true" />{label}</span></div>
        <div className="olib-tools"><button className="btn btn-sm" onClick={() => setUnlock({ type, id })}><KeyRound size={16} aria-hidden="true" />{t('visit.unlock')}</button></div>
      </li>
    );

    body = (
      <>
        <section className="acc-card" aria-label={res.profile.display_name}>
          <div className="acc-text">
            <div className="label" dir="auto">{res.profile.display_name}</div>
            <div className="hint" dir="ltr">@{res.profile.handle}</div>
            {res.profile.bio && <p className="hint" dir="auto">{res.profile.bio}</p>}
          </div>
        </section>

        {signedOut && <p className="hint olib-note">{t('visit.signInNeeded')}</p>}
        {!signedOut && !me && (lockedShelves.length > 0 || lib.state === 'locked' || res.locked_books.length > 0) && <p className="hint olib-note">{t('visit.profileNote')}</p>}

        {lib.state === 'unavailable' && <p className="hint" style={{ marginTop: 16 }}>{t('visit.unavailable')}</p>}

        {lib.state === 'locked' && (
          <section className="acc-card">
            <p className="hint"><Lock size={14} aria-hidden="true" style={{ verticalAlign: '-2px' }} /> {t('visit.lockedTitle')}</p>
            <div className="acc-actions"><button className="btn btn-sm btn-primary" onClick={() => setUnlock({ type: 'library', id: lib.id })}><KeyRound size={16} aria-hidden="true" />{t('visit.unlock')}</button></div>
          </section>
        )}

        {lib.state === 'open' && (lib.title || lib.description) && (
          <div className="acc-text" style={{ marginTop: 16 }}>
            {lib.title && <h2 style={{ margin: 0, fontSize: 18 }} dir="auto">{lib.title}</h2>}
            {lib.description && <p className="hint" dir="auto">{lib.description}</p>}
          </div>
        )}

        {openShelves.map((s) => (
          <div key={s.id}>
            <div className="olib-head"><h2 dir="auto">{s.name}</h2></div>
            {s.description && <p className="hint" dir="auto">{s.description}</p>}
            {(shelfOf.get(s.id) ?? []).length === 0 ? <p className="hint">{t('visit.shelfEmpty')}</p> : (
              <ul className="olib-list">{(shelfOf.get(s.id) ?? []).map((id) => <VisitedRow key={id} book={byId.get(id)!} />)}</ul>
            )}
          </div>
        ))}

        {(lockedShelves.length > 0 || res.locked_books.length > 0) && (
          <ul className="olib-list" style={{ marginTop: 18 }}>
            {lockedShelves.map((s) => lockCard(t('visit.lockedShelf'), 'shelf', s.id))}
            {res.locked_books.map((b) => lockCard(t('visit.lockedBook'), 'book', b.id))}
          </ul>
        )}

        {loose.length > 0 && (
          <div>
            <div className="olib-head"><h2>{openShelves.length ? t('visit.moreBooks') : t('onlineBooks.title')}</h2></div>
            <ul className="olib-list">{loose.map((b) => <VisitedRow key={b.id} book={b} />)}</ul>
          </div>
        )}

        {lib.state === 'open' && books.length === 0 && lockedShelves.length === 0 && res.locked_books.length === 0 && <p className="hint" style={{ marginTop: 16 }}>{t('visit.noBooks')}</p>}
        {unlock && <UnlockSheet type={unlock.type} id={unlock.id} onClose={() => setUnlock(null)} onUnlocked={() => void reload()} />}
      </>
    );
  }

  return (
    <div className="screen">
      <div className="screen-pad" style={{ maxWidth: 720 }}>
        <header className="page-head">
          <div style={{ marginInline: -10, marginBottom: -6 }}>
            <button className="icon-btn" onClick={goBack} aria-label={t('common.back')}><ArrowLeft className="flip" size={22} /></button>
          </div>
          <h1 dir="ltr">@{handle}</h1>
        </header>
        {body}
      </div>
    </div>
  );
}
