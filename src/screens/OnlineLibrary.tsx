import { useCallback, useEffect, useState } from 'react';
import { ArrowLeft, BookOpen, ChevronDown, ChevronUp, Pencil, Plus, Settings2, Trash2, Upload } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useOnline } from '../store/useOnline';
import { useT } from '../lib/i18n';
import { getFile } from '../lib/db';
import { effectiveBookMode, effectiveShelfMode, isLoosening, type AccessMode, type ShelfAccess } from '../lib/access';
import {
  createShelf, deleteShelf, fetchMyLibrary, hasAccessPassword, listMyBooks, listMyShelfLinks, listMyShelves, myBookHashes, onlineConfigured, publishBookFile,
  reorderShelves, setAccessPassword, updateLibrary, updateShelf,
  type OnlineBook, type OnlineLibrary, type OnlineShelf, type ShelfLink,
} from '../lib/online';
import { Sheet } from '../components/Sheet';
import { AddBooksSheet, BookSheet, ShelfBooksSheet, shelfModesOf } from '../components/OnlineBooks';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { AccessBadge, AccessPicker, PasswordBlock, PublicConfirm, codeOf } from '../components/AccessControls';

type Pending = { to: ShelfAccess; run: () => void } | null;

function LibrarySheet({ lib, onClose, onSaved }: { lib: OnlineLibrary; onClose: () => void; onSaved: (l: OnlineLibrary) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [title, setTitle] = useState(lib.title);
  const [desc, setDesc] = useState(lib.description);
  const [access, setAccess] = useState<AccessMode>(lib.default_access);
  const [pw, setPw] = useState('');
  const [has, setHas] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<Pending>(null);

  useEffect(() => {
    let alive = true;
    hasAccessPassword('library', lib.id).then((h) => alive && setHas(h), () => alive && setHas(null));
    return () => { alive = false; };
  }, [lib.id]);

  const needsPw = access === 'password' && has === false && pw.length === 0;
  const pwBad = pw.length > 0 && pw.length < 8;
  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (pw) await setAccessPassword('library', lib.id, pw);
      const next = await updateLibrary(lib.id, { title: title.trim(), description: desc.trim(), default_access: access });
      onSaved(next);
      toast('onlineLib.saved', 'success');
      onClose();
    } catch (e) {
      setErr(codeOf(e));
    } finally {
      setBusy(false);
    }
  };
  const submit = () => {
    if (access === 'public' && isLoosening(lib.default_access, 'public')) setConfirm({ to: 'public', run: () => void save() });
    else void save();
  };
  return (
    <Sheet title={t('onlineLib.settings')} onClose={onClose}>
      <form className="online-form" onSubmit={(e) => { e.preventDefault(); if (!needsPw && !pwBad && !busy) submit(); }}>
        <div>
          <label className="online-label" htmlFor="lib-title">{t('onlineLib.libTitle')}</label>
          <input id="lib-title" className="name-input" style={{ width: '100%' }} dir="auto" maxLength={80} value={title} onChange={(e) => setTitle(e.target.value)} />
        </div>
        <div>
          <label className="online-label" htmlFor="lib-desc">{t('onlineLib.description')}</label>
          <textarea id="lib-desc" className="textarea" dir="auto" maxLength={500} value={desc} onChange={(e) => setDesc(e.target.value)} />
        </div>
        <AccessPicker label={t('onlineLib.defaultAccess')} value={access} onChange={(v) => setAccess(v as AccessMode)} />
        <p className="hint">{t('onlineLib.defaultHint')}</p>
        {(access === 'password' || has) && <PasswordBlock type="library" id={lib.id} mode={access} value={pw} onChange={setPw} has={has} setHas={setHas} />}
        {err && <p className="acc-error" role="alert">{t(`online.err.${err}`)}</p>}
        <div className="acc-actions">
          <button className="btn btn-primary" type="submit" disabled={busy || needsPw || pwBad}>{busy ? '…' : t('online.save')}</button>
          <button className="btn btn-ghost" type="button" onClick={onClose}>{t('common.cancel')}</button>
        </div>
      </form>
      {confirm && <PublicConfirm onCancel={() => setConfirm(null)} onConfirm={() => { const c = confirm; setConfirm(null); c.run(); }} />}
    </Sheet>
  );
}

function ShelfSheet({ lib, shelf, nextPosition, onClose, onSaved, onCreated }: { lib: OnlineLibrary; shelf: OnlineShelf | null; nextPosition: number; onClose: () => void; onSaved: (s: OnlineShelf) => void; onCreated: (s: OnlineShelf) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [name, setName] = useState(shelf?.name ?? '');
  const [desc, setDesc] = useState(shelf?.description ?? '');
  const [access, setAccess] = useState<ShelfAccess>(shelf?.access ?? 'inherit');
  const [pw, setPw] = useState('');
  const [has, setHas] = useState<boolean | null>(shelf ? null : false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<Pending>(null);

  useEffect(() => {
    if (!shelf) return;
    let alive = true;
    hasAccessPassword('shelf', shelf.id).then((h) => alive && setHas(h), () => alive && setHas(null));
    return () => { alive = false; };
  }, [shelf]);

  const effective = effectiveShelfMode(access, lib.default_access);
  const own = access === 'password';
  const needsPw = own && has === false && pw.length === 0;
  const pwBad = pw.length > 0 && pw.length < 8;
  const nameOk = name.trim().length > 0;

  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (!shelf) {
        // new shelves start as "same as library"; privacy is chosen on the edit screen
        const next = await createShelf(lib.id, name, desc, nextPosition);
        onCreated(next);
        toast('onlineLib.created', 'success');
      } else {
        if (own && pw) await setAccessPassword('shelf', shelf.id, pw);
        const next = await updateShelf(shelf.id, { name, description: desc, access });
        onSaved(next);
        toast('onlineLib.saved', 'success');
      }
      onClose();
    } catch (e) {
      setErr(codeOf(e));
    } finally {
      setBusy(false);
    }
  };
  const submit = () => {
    if (shelf) {
      const before = effectiveShelfMode(shelf.access, lib.default_access);
      if (effective === 'public' && isLoosening(before, 'public')) return setConfirm({ to: 'public', run: () => void save() });
    }
    void save();
  };
  return (
    <Sheet title={shelf ? t('onlineLib.editShelf') : t('onlineLib.newShelf')} onClose={onClose}>
      <form className="online-form" onSubmit={(e) => { e.preventDefault(); if (nameOk && !needsPw && !pwBad && !busy) submit(); }}>
        <div>
          <label className="online-label" htmlFor="shelf-name">{t('onlineLib.shelfName')}</label>
          <input id="shelf-name" className="name-input" style={{ width: '100%' }} dir="auto" maxLength={80} autoFocus value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div>
          <label className="online-label" htmlFor="shelf-desc">{t('onlineLib.description')}</label>
          <textarea id="shelf-desc" className="textarea" dir="auto" maxLength={500} value={desc} onChange={(e) => setDesc(e.target.value)} />
        </div>
        {shelf ? (
          <>
            <AccessPicker label={t('onlineLib.shelfAccess')} allowInherit libraryDefault={lib.default_access} value={access} onChange={setAccess} />
            {own && <PasswordBlock type="shelf" id={shelf.id} mode={access} value={pw} onChange={setPw} has={has} setHas={setHas} />}
          </>
        ) : (
          <p className="hint">{t('onlineLib.newShelfHint')}</p>
        )}
        {err && <p className="acc-error" role="alert">{t(`online.err.${err}`)}</p>}
        <div className="acc-actions">
          <button className="btn btn-primary" type="submit" disabled={busy || !nameOk || needsPw || pwBad}>{busy ? '…' : shelf ? t('online.save') : t('onlineLib.create')}</button>
          <button className="btn btn-ghost" type="button" onClick={onClose}>{t('common.cancel')}</button>
        </div>
      </form>
      {confirm && <PublicConfirm onCancel={() => setConfirm(null)} onConfirm={() => { const c = confirm; setConfirm(null); c.run(); }} />}
    </Sheet>
  );
}

export function OnlineLibraryScreen() {
  const { t } = useT();
  const back = useApp((s) => s.back);
  const navigate = useApp((s) => s.navigate);
  const toast = useApp((s) => s.toast);
  const profile = useOnline((s) => s.profile);
  const status = useOnline((s) => s.status);
  const connect = useOnline((s) => s.connect);

  const [lib, setLib] = useState<OnlineLibrary | null>(null);
  const [shelves, setShelves] = useState<OnlineShelf[]>([]);
  const [books, setBooks] = useState<OnlineBook[]>([]);
  const [links, setLinks] = useState<ShelfLink[]>([]);
  const [hashes, setHashes] = useState<Map<string, string>>(new Map());
  const [up, setUp] = useState<Record<string, { pct: number } | { err: string }>>({});
  const localBooks = useApp((s) => s.books);
  const [addingBooks, setAddingBooks] = useState(false);
  const [editBook, setEditBook] = useState<OnlineBook | null>(null);
  const [shelfBooks, setShelfBooks] = useState<OnlineShelf | null>(null);
  const [load, setLoad] = useState<'loading' | 'ready' | 'error'>('loading');
  const [fail, setFail] = useState<string | null>(null);
  const [editLib, setEditLib] = useState(false);
  const [editing, setEditing] = useState<OnlineShelf | 'new' | null>(null);
  const [deleting, setDeleting] = useState<OnlineShelf | null>(null);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };

  const reload = useCallback(async () => {
    setLoad('loading');
    setFail(null);
    try {
      const [l, s, b, k] = await Promise.all([fetchMyLibrary(), listMyShelves(), listMyBooks(), listMyShelfLinks()]);
      setLib(l);
      setShelves(s);
      setBooks(b);
      setLinks(k);
      myBookHashes().then(setHashes, () => undefined);
      setLoad('ready');
    } catch (e) {
      setFail(codeOf(e));
      setLoad('error');
    }
  }, []);

  useEffect(() => {
    if (status === 'idle') void connect();
  }, [status, connect]);
  useEffect(() => {
    if (status === 'ready' && profile) void reload();
  }, [status, profile, reload]);

  const localFor = (b: OnlineBook) => {
    const h = hashes.get(b.id);
    return h ? localBooks.find((x) => x.hash === h && !x.remoteOnly && !x.tempRead) : undefined;
  };
  const uploadOne = async (b: OnlineBook) => {
    const local = localFor(b);
    if (!local) return;
    setUp((u) => ({ ...u, [b.id]: { pct: 0 } }));
    try {
      const file = await getFile(local.id);
      if (!file) throw new Error('missing');
      await publishBookFile(b, file, local.cover, (f) => setUp((u) => ({ ...u, [b.id]: { pct: Math.round(f * 100) } })));
      setBooks((all) => all.map((x) => (x.id === b.id ? { ...x, file_status: 'ready' } : x)));
      setUp((u) => { const n = { ...u }; delete n[b.id]; return n; });
    } catch (e) {
      setUp((u) => ({ ...u, [b.id]: { err: codeOf(e) === 'unknown' ? 'uploadFailed' : codeOf(e) } }));
    }
  };
  const waiting = books.filter((b) => b.file_status !== 'ready' && localFor(b) && !(up[b.id] && 'pct' in up[b.id]));
  const uploadAll = async () => { for (const b of waiting) await uploadOne(b); };

  const move = async (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= shelves.length) return;
    const prev = shelves;
    const next = [...shelves];
    [next[i], next[j]] = [next[j], next[i]];
    setShelves(next);
    try {
      await reorderShelves(next.map((s) => s.id));
    } catch (e) {
      setShelves(prev);
      toast(`online.err.${codeOf(e)}`, 'error');
    }
  };
  const remove = async (s: OnlineShelf) => {
    try {
      await deleteShelf(s.id);
      setShelves((all) => all.filter((x) => x.id !== s.id));
      setLinks((all) => all.filter((l) => l.shelf_id !== s.id));
      toast('onlineLib.deleted', 'info');
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    }
  };

  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (status === 'idle' || status === 'connecting' || load === 'loading') body = <p className="hint" role="status">{t('online.connecting')}</p>;
  else if (status === 'error' || load === 'error') {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${(status === 'error' ? useOnline.getState().error : fail) ?? 'unknown'}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => (status === 'error' ? void connect() : void reload())}>{t('online.retry')}</button></div>
      </div>
    );
  } else if (!profile) {
    body = (
      <div className="acc-card">
        <p className="hint">{t('onlineLib.noProfile')}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => navigate({ name: 'account' })}>{t('online.title')}</button></div>
      </div>
    );
  } else if (lib) {
    body = (
      <>
        <section className="acc-card" aria-label={t('onlineLib.settings')}>
          <div className="acc-text">
            <div className="label" dir="auto">{lib.title || t('onlineLib.untitled')}</div>
            {lib.description && <p className="hint" dir="auto">{lib.description}</p>}
          </div>
          <div><AccessBadge mode={lib.default_access} /></div>
          <div className="acc-actions"><button className="btn btn-sm" onClick={() => setEditLib(true)}><Settings2 size={16} aria-hidden="true" />{t('onlineLib.settings')}</button></div>
        </section>

        <div className="olib-head">
          <h2>{t('onlineLib.shelves')}</h2>
          <button className="btn btn-sm btn-primary" onClick={() => setEditing('new')}><Plus size={16} aria-hidden="true" />{t('onlineLib.newShelf')}</button>
        </div>
        {shelves.length === 0 ? (
          <p className="hint">{t('onlineLib.noShelves')}</p>
        ) : (
          <ul className="olib-list">
            {shelves.map((s, i) => (
              <li key={s.id} className="olib-row">
                <div className="olib-main">
                  <div className="label" dir="auto">{s.name}</div>
                  {s.description && <div className="hint olib-desc" dir="auto">{s.description}</div>}
                  <AccessBadge mode={effectiveShelfMode(s.access, lib.default_access)} inherited={s.access === 'inherit'} />
                </div>
                <div className="olib-tools">
                  <button className="icon-btn" onClick={() => setShelfBooks(s)} aria-label={t('onlineBooks.shelfBooks')}><BookOpen size={18} /><span className="olib-count">{links.filter((l) => l.shelf_id === s.id).length}</span></button>
                  <button className="icon-btn" disabled={i === 0} onClick={() => void move(i, -1)} aria-label={t('onlineLib.moveUp')}><ChevronUp size={20} /></button>
                  <button className="icon-btn" disabled={i === shelves.length - 1} onClick={() => void move(i, 1)} aria-label={t('onlineLib.moveDown')}><ChevronDown size={20} /></button>
                  <button className="icon-btn" onClick={() => setEditing(s)} aria-label={t('onlineLib.editShelf')}><Pencil size={18} /></button>
                  <button className="icon-btn" onClick={() => setDeleting(s)} aria-label={t('onlineLib.deleteShelf')}><Trash2 size={18} /></button>
                </div>
              </li>
            ))}
          </ul>
        )}

        <div className="olib-head">
          <h2>{t('onlineBooks.title')}</h2>
          <button className="btn btn-sm btn-primary" onClick={() => setAddingBooks(true)}><Plus size={16} aria-hidden="true" />{t('onlineBooks.addBtn')}</button>
        </div>
        {waiting.length > 1 && <div className="acc-actions" style={{ marginBottom: 10 }}><button className="btn btn-sm" onClick={() => void uploadAll()}><Upload size={16} aria-hidden="true" />{t('onlineBooks.uploadAll', { count: waiting.length })}</button></div>}
        <p className="hint">{t('onlineBooks.visibilityNote')}</p>
        {books.length === 0 ? (
          <p className="hint">{t('onlineBooks.empty')}</p>
        ) : (
          <ul className="olib-list">
            {books.map((b) => (
              <li key={b.id} className="olib-row">
                <div className="olib-main">
                  <div className="label" dir="auto">{b.title}</div>
                  {b.author && <div className="hint olib-desc" dir="auto">{b.author}</div>}
                  <AccessBadge mode={effectiveBookMode(b.access, shelfModesOf(b.id, links, shelves, lib), lib.default_access)} inherited={b.access === 'inherit'} />
                  {b.file_status === 'ready' ? <span className="hint">{t('onlineBooks.published')}</span> : (() => {
                    const u = up[b.id];
                    if (u && 'pct' in u) return <span className="hint" role="status">{t('onlineBooks.uploading', { pct: u.pct })}</span>;
                    if (u && 'err' in u) return <span className="acc-error" role="alert">{t(`online.err.${u.err}`)}</span>;
                    return <span className="hint">{localFor(b) ? t('onlineBooks.notUploaded') : t('onlineBooks.noLocalFile')}</span>;
                  })()}
                </div>
                <div className="olib-tools">
                  {b.file_status !== 'ready' && localFor(b) && !(up[b.id] && 'pct' in up[b.id]) && (
                    <button className="icon-btn" onClick={() => void uploadOne(b)} aria-label={t('onlineBooks.upload')}><Upload size={18} /></button>
                  )}
                  <button className="icon-btn" onClick={() => setEditBook(b)} aria-label={t('onlineBooks.edit')}><Pencil size={18} /></button>
                </div>
              </li>
            ))}
          </ul>
        )}

        {addingBooks && <AddBooksSheet onClose={() => setAddingBooks(false)} onAdded={(b) => setBooks((all) => [b, ...all.filter((x) => x.id !== b.id)])} />}
        {editBook && <BookSheet book={editBook} lib={lib} shelves={shelves} links={links} onClose={() => setEditBook(null)} onSaved={(n) => setBooks((all) => all.map((x) => (x.id === n.id ? n : x)))} onDeleted={(id) => { setBooks((all) => all.filter((x) => x.id !== id)); setLinks((all) => all.filter((l) => l.book_id !== id)); }} />}
        {shelfBooks && <ShelfBooksSheet shelf={shelfBooks} books={books} links={links} onClose={() => setShelfBooks(null)} onLinks={setLinks} />}

        {editLib && <LibrarySheet lib={lib} onClose={() => setEditLib(false)} onSaved={setLib} />}
        {editing && (
          <ShelfSheet
            lib={lib}
            shelf={editing === 'new' ? null : editing}
            nextPosition={shelves.reduce((m, x) => Math.max(m, x.position), -1) + 1}
            onClose={() => setEditing(null)}
            onSaved={(n) => setShelves((all) => all.map((x) => (x.id === n.id ? n : x)))}
            onCreated={(n) => setShelves((all) => [...all, n])}
          />
        )}
        {deleting && (
          <ConfirmDialog danger title={t('onlineLib.deleteTitle')} body={t('onlineLib.deleteBody', { name: deleting.name })} confirmLabel={t('onlineLib.deleteConfirm')} onCancel={() => setDeleting(null)} onConfirm={() => { const s = deleting; setDeleting(null); void remove(s); }} />
        )}
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
          <h1>{t('onlineLib.title')}</h1>
        </header>
        {body}
      </div>
    </div>
  );
}
