import { useEffect, useState } from 'react';
import { ArrowLeft, Ban, Bell, BellOff, Check, Search, UserMinus, X } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useOnline } from '../store/useOnline';
import { useSocial } from '../store/useSocial';
import { useT } from '../lib/i18n';
import { handleProblem, normalizeHandle } from '../lib/handle';
import {
  blockUser, cancelFriendRequest, findPerson, onlineConfigured, removeFriend, respondFriendRequest, sendFriendRequest,
  setSubscriptionMuted, unblockUser, unsubscribe, type Person, type Subscription,
} from '../lib/online';
import { relationOf, requestWith } from '../lib/social';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { codeOf } from '../components/AccessControls';

type Tab = 'friends' | 'requests' | 'following' | 'blocked';
type Confirm = { kind: 'remove' | 'block'; person: Person } | null;

function PersonRow({ person, note, children }: { person: Person; note?: string; children: React.ReactNode }) {
  return (
    <li className="olib-row">
      <div className="olib-main">
        <div className="label" dir="auto">{person.display_name}</div>
        <div className="hint" dir="ltr">@{person.handle}</div>
        {note && <div className="hint">{note}</div>}
        {person.bio && <div className="hint olib-desc" dir="auto">{person.bio}</div>}
      </div>
      <div className="olib-tools" style={{ gap: 6 }}>{children}</div>
    </li>
  );
}

export function PeopleScreen() {
  const { t, n } = useT();
  const navigate = useApp((s) => s.navigate);
  const back = useApp((s) => s.back);
  const toast = useApp((s) => s.toast);
  const me = useOnline((s) => s.profile);
  const { rel, subs, status, error, load } = useSocial();
  const [tab, setTab] = useState<Tab>('friends');
  const [handle, setHandle] = useState('');
  const [found, setFound] = useState<Person | 'none' | null>(null);
  const [searching, setSearching] = useState(false);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<Confirm>(null);

  const goBack = () => { if (!back()) navigate({ name: 'library' }, { replace: true }); };
  useEffect(() => { void load(); }, [load]);

  const h = normalizeHandle(handle);
  const bad = h.length > 0 && handleProblem(h) !== null && handleProblem(h) !== 'reserved';

  /** runs one action, shows its result, and always re-reads the lists (the server is the truth) */
  const act = async (fn: () => Promise<void>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast(ok, 'success');
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    } finally {
      await load();
      setBusy(false);
    }
  };

  const search = async () => {
    if (!h || bad || searching) return;
    setSearching(true);
    try {
      setFound((await findPerson(h)) ?? 'none');
    } catch (e) {
      toast(`online.err.${codeOf(e)}`, 'error');
    } finally {
      setSearching(false);
    }
  };

  const openLib = (p: Person) => navigate({ name: 'visit', handle: p.handle });
  const btn = (label: string, onClick: () => void, extra = '', disabled = busy) => (
    <button className={`btn btn-sm ${extra}`} disabled={disabled} onClick={onClick}>{label}</button>
  );

  /** the buttons that make sense for one person, given how we stand with them */
  const actionsFor = (p: Person) => {
    const r = relationOf(rel, p.id, me?.id);
    const req = requestWith(rel, p.id);
    if (r === 'self') return <span className="hint">{t('people.you')}</span>;
    return (
      <>
        {r === 'none' && btn(t('people.add'), () => void act(() => sendFriendRequest(p.id), 'people.requestSent'), 'btn-primary')}
        {r === 'outgoing' && req && btn(t('people.cancelRequest'), () => void act(() => cancelFriendRequest(req.id), 'people.cancelled'))}
        {r === 'incoming' && req && (
          <>
            {btn(t('people.accept'), () => void act(() => respondFriendRequest(req.id, true), 'people.accepted'), 'btn-primary')}
            {btn(t('people.decline'), () => void act(() => respondFriendRequest(req.id, false), 'people.declined'))}
          </>
        )}
        {r === 'friend' && <span className="olib-badge"><Check size={14} aria-hidden="true" />{t('people.isFriend')}</span>}
        {btn(t('people.openLibrary'), () => openLib(p), '', false)}
        {r === 'friend' && <button className="icon-btn" disabled={busy} onClick={() => setConfirm({ kind: 'remove', person: p })} aria-label={t('people.remove')}><UserMinus size={18} /></button>}
        <button className="icon-btn" disabled={busy} onClick={() => setConfirm({ kind: 'block', person: p })} aria-label={t('people.block')}><Ban size={18} /></button>
      </>
    );
  };

  const subRow = (s: Subscription) => {
    const name = s.target_name ?? (s.available ? '' : t('people.unavailable'));
    return (
      <li key={s.id} className="olib-row">
        <div className="olib-main">
          <div className="label" dir="auto">{name}</div>
          <div className="hint">{t(`people.type.${s.target_type}`)}{s.owner_handle && <> · <span dir="ltr">@{s.owner_handle}</span></>}{s.muted && <> · {t('people.muted')}</>}</div>
        </div>
        <div className="olib-tools" style={{ gap: 6 }}>
          {s.owner_handle && s.available && btn(t('people.openLibrary'), () => navigate({ name: 'visit', handle: s.owner_handle! }), '', false)}
          <button className="icon-btn" disabled={busy} onClick={() => void act(() => setSubscriptionMuted(s.id, !s.muted))} aria-label={s.muted ? t('people.unmute') : t('people.mute')} aria-pressed={s.muted}>
            {s.muted ? <BellOff size={18} /> : <Bell size={18} />}
          </button>
          <button className="icon-btn" disabled={busy} onClick={() => void act(() => unsubscribe(s.id), 'people.unfollowed')} aria-label={t('people.unfollow')}><X size={18} /></button>
        </div>
      </li>
    );
  };

  const reqCount = (rel?.incoming.length ?? 0) + (rel?.outgoing.length ?? 0);
  const counts: Record<Tab, number> = { friends: rel?.friends.length ?? 0, requests: reqCount, following: subs?.length ?? 0, blocked: rel?.blocked.length ?? 0 };
  const label: Record<Tab, string> = { friends: t('people.tabFriends'), requests: t('people.tabRequests'), following: t('people.tabFollowing'), blocked: t('people.tabBlocked') };

  let body;
  if (!onlineConfigured) body = <p className="hint">{t('online.notConfigured')}</p>;
  else if (!me) {
    body = (
      <div className="acc-card">
        <p className="hint">{t('people.needProfile')}</p>
        <div className="acc-actions"><button className="btn btn-sm btn-primary" onClick={() => navigate({ name: 'account' })}>{t('account.title')}</button></div>
      </div>
    );
  } else if (status === 'error' && !rel) {
    body = (
      <div className="acc-card">
        <p className="acc-error" role="alert">{t(`online.err.${error ?? 'unknown'}`)}</p>
        <div className="acc-actions"><button className="btn btn-sm" onClick={() => void load()}>{t('online.retry')}</button></div>
      </div>
    );
  } else if (!rel || !subs) {
    body = <p className="hint" role="status">{t('people.loading')}</p>;
  } else {
    body = (
      <>
        <form className="field" style={{ marginTop: 4 }} onSubmit={(e) => { e.preventDefault(); void search(); }}>
          <Search size={18} aria-hidden="true" />
          <input dir="ltr" autoCapitalize="none" autoCorrect="off" spellCheck={false} maxLength={32} value={handle} placeholder="@handle" aria-label={t('people.find')}
            onChange={(e) => { setHandle(e.target.value); setFound(null); }} />
          <button className="btn btn-sm" type="submit" disabled={!h || bad || searching}>{searching ? '…' : t('people.findGo')}</button>
        </form>
        {found === 'none' && <p className="hint" role="status" style={{ marginTop: 10 }}>{t('people.notFound')}</p>}
        {found && found !== 'none' && <ul className="olib-list" style={{ marginTop: 10 }}><PersonRow person={found}>{actionsFor(found)}</PersonRow></ul>}

        <div className="chips" role="group" aria-label={t('people.title')} style={{ marginTop: 16 }}>
          {(['friends', 'requests', 'following', 'blocked'] as Tab[]).map((x) => (
            <button key={x} className="chip" aria-pressed={tab === x} onClick={() => setTab(x)}>
              {label[x]}{counts[x] > 0 && <span className="count-dot">{n(counts[x])}</span>}
            </button>
          ))}
        </div>

        {tab === 'friends' && (rel.friends.length === 0 ? <p className="hint" style={{ marginTop: 14 }}>{t('people.noFriends')}</p> : (
          <ul className="olib-list" style={{ marginTop: 12 }}>{rel.friends.map((p) => <PersonRow key={p.id} person={p}>{actionsFor(p)}</PersonRow>)}</ul>
        ))}

        {tab === 'requests' && (reqCount === 0 ? <p className="hint" style={{ marginTop: 14 }}>{t('people.noRequests')}</p> : (
          <>
            {rel.incoming.length > 0 && (
              <>
                <div className="olib-head"><h2>{t('people.incoming')}</h2></div>
                <ul className="olib-list">{rel.incoming.map((p) => <PersonRow key={p.request_id} person={p}>{actionsFor(p)}</PersonRow>)}</ul>
              </>
            )}
            {rel.outgoing.length > 0 && (
              <>
                <div className="olib-head"><h2>{t('people.outgoing')}</h2></div>
                <ul className="olib-list">{rel.outgoing.map((p) => <PersonRow key={p.request_id} person={p}>{actionsFor(p)}</PersonRow>)}</ul>
              </>
            )}
          </>
        ))}

        {tab === 'following' && (
          <>
            <p className="hint olib-note">{t('people.followHint')}</p>
            {subs.length === 0 ? <p className="hint">{t('people.noFollowing')}</p> : <ul className="olib-list">{subs.map(subRow)}</ul>}
          </>
        )}

        {tab === 'blocked' && (rel.blocked.length === 0 ? <p className="hint" style={{ marginTop: 14 }}>{t('people.noBlocked')}</p> : (
          <ul className="olib-list" style={{ marginTop: 12 }}>
            {rel.blocked.map((p) => (
              <PersonRow key={p.id} person={p}>{btn(t('people.unblock'), () => void act(() => unblockUser(p.id), 'people.unblocked'))}</PersonRow>
            ))}
          </ul>
        ))}
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
          <h1>{t('people.title')}</h1>
        </header>
        {body}
        {confirm && (
          <ConfirmDialog
            title={t(confirm.kind === 'remove' ? 'people.removeTitle' : 'people.blockTitle', { name: confirm.person.display_name })}
            body={t(confirm.kind === 'remove' ? 'people.removeBody' : 'people.blockBody', { name: confirm.person.display_name })}
            confirmLabel={t(confirm.kind === 'remove' ? 'people.remove' : 'people.block')}
            danger
            onCancel={() => setConfirm(null)}
            onConfirm={() => {
              const c = confirm;
              setConfirm(null);
              void act(() => (c.kind === 'remove' ? removeFriend(c.person.id) : blockUser(c.person.id)), c.kind === 'remove' ? 'people.removed' : 'people.blocked').then(() => setFound(null));
            }}
          />
        )}
      </div>
    </div>
  );
}

