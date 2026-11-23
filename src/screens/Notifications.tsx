import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, Trash2, X } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useInbox } from '../store/useInbox';
import { useT } from '../lib/i18n';
import {
  DEFAULT_PREFS, deleteNotifications, fetchNotificationPrefs, fetchNotifications, markNotificationsRead, onlineConfigured,
  saveNotificationPrefs, type AppNotification, type NotificationPrefs,
} from '../lib/online';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { codeOf } from '../components/AccessControls';

const PREF_KEYS: (keyof NotificationPrefs)[] = ['friend_requests', 'friend_accepted', 'new_books'];

/** The in-app inbox. Items are read from the server when this screen opens; nothing is pushed to the phone. */
export function NotificationsScreen() {
  const { t } = useT();
  const navigate = useApp((s) => s.navigate);
  const back = useApp((s) => s.back);
  const toast = useApp((s) => s.toast);
  const unread = useInbox((s) => s.unread);
  const [items, setItems] = useState<AppNotification[]>([]);
  // what was unread WHEN LOADED stays highlighted during this visit even though it is marked read on the server
  const [fresh, setFresh] = useState<Set<string>>(new Set());
  const [more, setMore] = useState(false);
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading');
  const [fail, setFail] = useState('unknown');
  const [paging, setPaging] = useState(false);
  const [prefs, setPrefs] = useState<NotificationPrefs>(DEFAULT_PREFS);
  const [confirmClear, setConfirmClear] = useState(false);
  const seq = useRef(0);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };

  const load = useCallback(async (offset: number) => {
    const mine = ++seq.current;
    if (offset === 0) setState('loading'); else setPaging(true);
    try {
      const p = await fetchNotifications(offset);
      if (mine !== seq.current) return;
      setItems((cur) => (offset === 0 ? p.items : [...cur, ...p.items.filter((x) => !cur.some((y) => y.id === x.id))]));
      setMore(p.more);
      setState('ready');
      const ids = p.items.filter((x) => !x.read_at).map((x) => x.id);
      if (ids.length) {
        setFresh((cur) => new Set([...cur, ...ids]));
        markNotificationsRead(ids).then(() => useInbox.getState().refresh()).catch(() => undefined);
      }
    } catch (e) {
      if (mine !== seq.current) return;
      setFail(codeOf(e));
      setState('error');
    } finally {
      if (mine === seq.current) setPaging(false);
    }
  }, []);

  useEffect(() => {
    if (!onlineConfigured) return;
    void load(0);
    fetchNotificationPrefs().then(setPrefs).catch(() => undefined);
  }, [load]);

  const act = async (fn: () => Promise<void>) => {
    try {
      await fn();
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    }
  };

  const text = (n: AppNotification): string => {
    const name = n.actor_name || n.actor_handle || '';
    const title = n.resource_title;
    switch (n.type) {
      case 'friend_request': return t('notif.friend_request', { name });
      case 'friend_accepted': return t('notif.friend_accepted', { name });
      case 'new_book': return title ? t('notif.new_book', { name, title }) : t('notif.new_book_untitled', { name });
      case 'content_removed': { const reason = t(`report.reason.${n.detail ?? 'other'}`); return title ? t('notif.content_removed', { title, reason }) : t('notif.content_removed_untitled', { reason }); }
      case 'content_restored': return title ? t('notif.content_restored', { title }) : t('notif.content_restored_untitled');
      default: return t(`notif.report_${n.detail === 'removed' || n.detail === 'dismissed' ? n.detail : 'noted'}`);
    }
  };

  const open = (n: AppNotification) => {
    if (n.type === 'friend_request') navigate({ name: 'people' });
    else if ((n.type === 'friend_accepted' || n.type === 'new_book') && n.actor_handle) navigate({ name: 'visit', handle: n.actor_handle });
    else if (n.type === 'content_removed' || n.type === 'content_restored') navigate({ name: 'onlineLibrary' });
  };

  const togglePref = (k: keyof NotificationPrefs) => {
    const next = { ...prefs, [k]: !prefs[k] };
    setPrefs(next);
    saveNotificationPrefs(next).catch((e) => { setPrefs(prefs); toast(`online.err.${codeOf(e)}`, 'error'); });
  };

  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (state === 'loading') body = <p className="hint" role="status">{t('people.loading')}</p>;
  else if (state === 'error') {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${fail}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => void load(0)}>{t('online.retry')}</button></div>
      </div>
    );
  } else if (items.length === 0) body = <p className="hint" role="status">{t('notif.empty')}</p>;
  else {
    body = (
      <>
        <ul className="olib-list">
          {items.map((n) => (
            <li key={n.id} className="olib-row" style={fresh.has(n.id) ? { borderInlineStart: '3px solid var(--accent)' } : undefined}>
              <button className="olib-main" style={{ textAlign: 'start' }} onClick={() => open(n)}>
                <div className="label" dir="auto">{text(n)}</div>
                <div className="hint">{new Date(n.created_at).toLocaleString()}{fresh.has(n.id) && <> · {t('notif.unread')}</>}</div>
              </button>
              <div className="olib-tools">
                <button className="icon-btn" aria-label={t('common.delete')} onClick={() => void act(async () => { await deleteNotifications([n.id]); setItems((c) => c.filter((x) => x.id !== n.id)); })}><X size={18} /></button>
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
          <h1>{t('notif.title')}</h1>
        </header>
        <p className="hint olib-note">{t('notif.note')}</p>
        {onlineConfigured && state === 'ready' && (items.length > 0 || unread > 0) && (
          <div className="acc-actions" style={{ marginBottom: 10 }}>
            {unread > 0 && <button className="btn btn-sm" onClick={() => void act(async () => { await markNotificationsRead(); await useInbox.getState().refresh(); })}>{t('notif.markAll')}</button>}
            {items.length > 0 && <button className="btn btn-sm" onClick={() => setConfirmClear(true)}><Trash2 size={16} aria-hidden="true" />{t('notif.clear')}</button>}
          </div>
        )}
        {body}

        {onlineConfigured && (
          <div className="acc-card" style={{ marginTop: 20 }}>
            <div className="label" style={{ marginBottom: 6 }}>{t('notif.settings')}</div>
            {PREF_KEYS.map((k) => (
              <div key={k} className="setting-row">
                <div className="label">{t(`notif.pref.${k}`)}</div>
                <button role="switch" aria-checked={prefs[k]} aria-label={t(`notif.pref.${k}`)} className="switch" onClick={() => togglePref(k)} />
              </div>
            ))}
          </div>
        )}

        {confirmClear && (
          <ConfirmDialog
            title={t('notif.clearTitle')}
            body={t('notif.clearBody')}
            confirmLabel={t('notif.clear')}
            danger
            onCancel={() => setConfirmClear(false)}
            onConfirm={() => { setConfirmClear(false); void act(async () => { await deleteNotifications(); setItems([]); setMore(false); await useInbox.getState().refresh(); }); }}
          />
        )}
      </div>
    </div>
  );
}
