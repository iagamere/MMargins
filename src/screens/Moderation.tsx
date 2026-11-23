import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useInbox } from '../store/useInbox';
import { useT } from '../lib/i18n';
import { fetchModerationQueue, onlineConfigured, resolveReport, restoreBook, type ModerationAction, type ModerationItem } from '../lib/online';
import { Sheet } from '../components/Sheet';
import { codeOf } from '../components/AccessControls';

type Tab = 'open' | 'handled';

/** Moderators only. The database decides who is one; a non-moderator sees nothing but a refusal. */
export function ModerationScreen() {
  const { t, n } = useT();
  const navigate = useApp((s) => s.navigate);
  const back = useApp((s) => s.back);
  const toast = useApp((s) => s.toast);
  const moderator = useInbox((s) => s.moderator);
  const [tab, setTab] = useState<Tab>('open');
  const [items, setItems] = useState<ModerationItem[]>([]);
  const [more, setMore] = useState(false);
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading');
  const [fail, setFail] = useState('unknown');
  const [paging, setPaging] = useState(false);
  const [pending, setPending] = useState<{ item: ModerationItem; action: ModerationAction } | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const seq = useRef(0);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };

  const load = useCallback(async (offset: number) => {
    const mine = ++seq.current;
    if (offset === 0) setState('loading'); else setPaging(true);
    try {
      const p = await fetchModerationQueue(tab, offset);
      if (mine !== seq.current) return;
      setItems((cur) => (offset === 0 ? p.items : [...cur, ...p.items.filter((x) => !cur.some((y) => y.id === x.id))]));
      setMore(p.more);
      setState('ready');
    } catch (e) {
      if (mine !== seq.current) return;
      setFail(codeOf(e));
      setState('error');
    } finally {
      if (mine === seq.current) setPaging(false);
    }
  }, [tab]);

  useEffect(() => { if (onlineConfigured) void load(0); }, [load]);

  const submit = async () => {
    if (!pending || busy) return;
    setBusy(true);
    try {
      await resolveReport(pending.item.id, pending.action, note);
      toast('mod.done', 'success');
      setPending(null);
      setNote('');
      await load(0);
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    } finally {
      setBusy(false);
    }
  };

  const restore = async (it: ModerationItem) => {
    setBusy(true);
    try {
      await restoreBook(it.target_id);
      toast('mod.restored', 'success');
      await load(0);
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    } finally {
      setBusy(false);
    }
  };

  const actionLabel = (a: ModerationAction) => t(a === 'dismiss' ? 'mod.dismiss' : a === 'takedown' ? 'mod.takedown' : 'mod.noted');

  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (moderator === false) body = <p className="acc-error" role="alert">{t('online.err.notAllowed')}</p>;
  else if (state === 'loading') body = <p className="hint" role="status">{t('people.loading')}</p>;
  else if (state === 'error') {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${fail}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => void load(0)}>{t('online.retry')}</button></div>
      </div>
    );
  } else if (items.length === 0) body = <p className="hint" role="status">{t(tab === 'open' ? 'mod.empty' : 'mod.emptyHandled')}</p>;
  else {
    body = (
      <>
        <ul className="olib-list">
          {items.map((it) => (
            <li key={it.id} className="olib-row" style={{ alignItems: 'flex-start' }}>
              <div className="olib-main">
                <div className="label" dir="auto">{it.target_title ?? t('mod.deleted')}</div>
                <div className="hint">{t(`mod.type.${it.target_type}`)} · {t(`report.reason.${it.reason}`)}{it.owner_handle && <> · {t('mod.owner', { handle: it.owner_handle })}</>}</div>
                <div className="hint">{t('mod.reportedBy', { handle: it.reporter_handle })} · {new Date(it.created_at).toLocaleDateString()}</div>
                {it.details && <div className="hint olib-desc" dir="auto">{it.details}</div>}
                {tab === 'open' && it.open_reports > 1 && <div className="hint">{t('mod.count', { count: n(it.open_reports) })}</div>}
                {tab === 'handled' && it.resolution && <div className="hint">{t(`mod.resolution.${it.resolution}`)}{it.note && <> · <span dir="auto">{it.note}</span></>}</div>}
                {it.book_removed && <div className="hint">{t('mod.bookRemoved')}</div>}
              </div>
              <div className="olib-tools" style={{ flexWrap: 'wrap', gap: 6 }}>
                {tab === 'open' && (
                  <>
                    <button className="btn btn-sm" disabled={busy} onClick={() => { setNote(''); setPending({ item: it, action: 'dismiss' }); }}>{t('mod.dismiss')}</button>
                    {it.target_type === 'book' && it.target_title !== null && <button className="btn btn-sm btn-primary" disabled={busy} onClick={() => { setNote(''); setPending({ item: it, action: 'takedown' }); }}>{t('mod.takedown')}</button>}
                    <button className="btn btn-sm" disabled={busy} onClick={() => { setNote(''); setPending({ item: it, action: 'noted' }); }}>{t('mod.noted')}</button>
                  </>
                )}
                {tab === 'handled' && it.book_removed && <button className="btn btn-sm" disabled={busy} onClick={() => void restore(it)}>{t('mod.restore')}</button>}
              </div>
            </li>
          ))}
        </ul>
        {more && <div className="acc-actions" style={{ marginTop: 12 }}><button className="btn btn-sm" disabled={paging} onClick={() => void load(items.length)}>{paging ? '…' : t('notif.more')}</button></div>}
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
          <h1>{t('mod.title')}</h1>
        </header>
        <p className="hint olib-note">{t('mod.metaOnly')}</p>
        <div className="chips" role="group" aria-label={t('mod.title')} style={{ margin: '8px 0 12px' }}>
          {(['open', 'handled'] as Tab[]).map((x) => (
            <button key={x} className="chip" aria-pressed={tab === x} onClick={() => { if (x !== tab) { setMore(false); setTab(x); } }}>{t(x === 'open' ? 'mod.tabOpen' : 'mod.tabHandled')}</button>
          ))}
        </div>
        {body}
        {pending && (
          <Sheet title={actionLabel(pending.action)} onClose={() => setPending(null)}>
            <p className="label" dir="auto">{pending.item.target_title ?? t('mod.deleted')}</p>
            {pending.action === 'takedown' && <p className="hint">{t('mod.takedownBody')}</p>}
            <div className="label" style={{ margin: '12px 0 8px' }}>{t('mod.note')}</div>
            <textarea className="textarea" dir="auto" maxLength={1000} value={note} placeholder={t('mod.notePlaceholder')} onChange={(e) => setNote(e.target.value)} />
            <div className="acc-actions" style={{ marginTop: 14 }}>
              <button className={`btn ${pending.action === 'takedown' ? 'btn-primary' : ''}`} disabled={busy} onClick={() => void submit()}>{busy ? '…' : actionLabel(pending.action)}</button>
            </div>
          </Sheet>
        )}
      </div>
    </div>
  );
}
