import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, Search, X } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import {
  cleanQuery, discoverBooks, discoverLibraries, onlineConfigured,
  type DiscoveredBook, type DiscoveredLibrary,
} from '../lib/online';
import { codeOf } from '../components/AccessControls';
import { VisitedRow } from './Visit';

type Tab = 'books' | 'libraries';

/** Public books and libraries only. The database decides what is public (and hides blocked people);
 *  this screen just asks, pages and shows. */
export function DiscoverScreen() {
  const { t, n } = useT();
  const navigate = useApp((s) => s.navigate);
  const back = useApp((s) => s.back);
  const [tab, setTab] = useState<Tab>('books');
  const [query, setQuery] = useState('');
  const [q, setQ] = useState('');
  const [books, setBooks] = useState<DiscoveredBook[]>([]);
  const [libs, setLibs] = useState<DiscoveredLibrary[]>([]);
  const [more, setMore] = useState(false);
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading');
  const [fail, setFail] = useState('unknown');
  const [paging, setPaging] = useState(false);
  // only the newest request may write its result (typing fast must not show stale results)
  const seq = useRef(0);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };

  useEffect(() => {
    const id = setTimeout(() => setQ(cleanQuery(query)), 350);
    return () => clearTimeout(id);
  }, [query]);

  const run = useCallback(async (offset: number) => {
    const mine = ++seq.current;
    if (offset === 0) setState('loading');
    else setPaging(true);
    try {
      if (tab === 'books') {
        const p = await discoverBooks(q, offset);
        if (mine !== seq.current) return;
        setBooks((cur) => (offset === 0 ? p.items : [...cur, ...p.items.filter((b) => !cur.some((x) => x.id === b.id))]));
        setMore(p.more);
      } else {
        const p = await discoverLibraries(q, offset);
        if (mine !== seq.current) return;
        setLibs((cur) => (offset === 0 ? p.items : [...cur, ...p.items.filter((l) => !cur.some((x) => x.handle === l.handle))]));
        setMore(p.more);
      }
      setState('ready');
    } catch (e) {
      if (mine !== seq.current) return;
      setFail(codeOf(e));
      setState('error');
    } finally {
      if (mine === seq.current) setPaging(false);
    }
  }, [tab, q]);

  useEffect(() => { if (onlineConfigured) void run(0); }, [run]);

  const shown = tab === 'books' ? books.length : libs.length;
  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (state === 'loading') body = <p className="hint" role="status" style={{ marginTop: 16 }}>{t('discover.loading')}</p>;
  else if (state === 'error') {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${fail}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => void run(0)}>{t('online.retry')}</button></div>
      </div>
    );
  } else if (shown === 0) {
    const none = q ? (tab === 'books' ? 'discover.noBooks' : 'discover.noLibraries') : 'discover.empty';
    body = <p className="hint" role="status" style={{ marginTop: 16 }}>{t(none)}</p>;
  } else {
    body = (
      <>
        <ul className="olib-list" style={{ marginTop: 14 }}>
          {tab === 'books'
            ? books.map((b) => <VisitedRow key={b.id} book={b} owner={t('discover.by', { handle: b.owner_handle })} />)
            : libs.map((l) => (
              <li key={l.handle} className="olib-row">
                <div className="olib-main">
                  <div className="label" dir="auto">{l.library_title || l.display_name}</div>
                  <div className="hint" dir="auto">{l.display_name} · <span dir="ltr">@{l.handle}</span></div>
                  {l.bio && <div className="hint olib-desc" dir="auto">{l.bio}</div>}
                  <div className="hint">{t('discover.bookCount', { count: n(l.book_count) })}</div>
                </div>
                <div className="olib-tools">
                  <button className="btn btn-sm" onClick={() => navigate({ name: 'visit', handle: l.handle })}>{t('discover.openLibrary')}</button>
                </div>
              </li>
            ))}
        </ul>
        {more && (
          <div className="acc-actions" style={{ marginTop: 12 }}>
            <button className="btn btn-sm" disabled={paging} onClick={() => void run(shown)}>{paging ? '…' : t('discover.more')}</button>
          </div>
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
          <h1>{t('discover.title')}</h1>
        </header>
        <label className="field">
          <Search size={18} aria-hidden="true" />
          <input type="search" value={query} onChange={(e) => setQuery(e.target.value)} maxLength={120} placeholder={t('discover.search')} aria-label={t('discover.search')} enterKeyHint="search" />
          {query && (
            <button type="button" className="icon-btn" style={{ width: 36, height: 36 }} onClick={() => setQuery('')} aria-label={t('common.clear')}><X size={18} /></button>
          )}
        </label>
        <div className="chips" role="group" aria-label={t('discover.title')} style={{ marginTop: 10 }}>
          {(['books', 'libraries'] as Tab[]).map((x) => (
            <button key={x} className="chip" aria-pressed={tab === x} onClick={() => { if (x !== tab) { setMore(false); setTab(x); } }}>{t(`discover.${x}`)}</button>
          ))}
        </div>
        <p className="hint olib-note">{t('discover.hint')}</p>
        {body}
      </div>
    </div>
  );
}
