import { useEffect, useState } from 'react';
import { Globe, Library, RefreshCw, Search, Trash2 } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useOnline } from '../store/useOnline';
import { useT } from '../lib/i18n';
import { signIn } from '../lib/auth';
import { handleProblem, normalizeHandle } from '../lib/handle';
import { OnlineError, changeHandle, createProfile, deleteOnlineAccount, isHandleAvailable, onlineConfigured, updateMyProfile, type OnlineErrorCode } from '../lib/online';
import { ConfirmDialog } from './ConfirmDialog';
import { VisitSheet } from '../screens/Visit';

type Check = 'idle' | 'checking' | 'ok' | 'taken' | { problem: string } | 'error';

/** Handle input with instant local rules and a live availability check against the database. */
function HandleField({ value, onChange, current, onState }: { value: string; onChange: (v: string) => void; current?: string; onState: (ok: boolean) => void }) {
  const { t } = useT();
  const [check, setCheck] = useState<Check>('idle');

  useEffect(() => {
    const h = normalizeHandle(value);
    if (!h || h === current) {
      setCheck('idle');
      onState(false);
      return;
    }
    const problem = handleProblem(h);
    if (problem) {
      setCheck({ problem });
      onState(false);
      return;
    }
    setCheck('checking');
    onState(false);
    let alive = true;
    const timer = setTimeout(async () => {
      try {
        const free = await isHandleAvailable(h);
        if (!alive) return;
        setCheck(free ? 'ok' : 'taken');
        onState(free);
      } catch {
        if (alive) setCheck('error');
      }
    }, 450);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, current]);

  const msg =
    check === 'checking' ? t('online.handle.checking')
    : check === 'ok' ? t('online.handle.available')
    : check === 'taken' ? t('online.handle.taken')
    : check === 'error' ? t('online.err.offline')
    : typeof check === 'object' ? t(`online.handle.problem.${check.problem}`)
    : '';
  const good = check === 'ok';
  return (
    <div>
      <label className="online-label" htmlFor="online-handle">{t('online.handle')}</label>
      <div className="field">
        <span aria-hidden="true" className="muted">@</span>
        <input id="online-handle" dir="ltr" value={value} maxLength={30} autoCapitalize="none" autoCorrect="off" spellCheck={false} placeholder={t('online.handlePlaceholder')} onChange={(e) => onChange(e.target.value)} />
      </div>
      <p className={'online-status ' + (good ? 'ok' : check === 'taken' || typeof check === 'object' ? 'bad' : '')} role="status" aria-live="polite">{msg}</p>
    </div>
  );
}

export function OnlineProfileCard() {
  const { t } = useT();
  const account = useApp((s) => s.account);
  const toast = useApp((s) => s.toast);
  const { status, profile, error, connect, setProfile, reset } = useOnline();

  const [handle, setHandle] = useState('');
  const [handleOk, setHandleOk] = useState(false);
  const [name, setName] = useState('');
  const [bio, setBio] = useState('');
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [fail, setFail] = useState<OnlineErrorCode | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [visiting, setVisiting] = useState(false);

  useEffect(() => {
    if (account && status === 'idle') void connect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account]);

  useEffect(() => {
    if (!profile) setName((n) => n || account?.name || '');
  }, [profile, account?.name]);

  if (!account) return null;
  const codeOf = (e: unknown): OnlineErrorCode => (e instanceof OnlineError ? e.code : 'unknown');
  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setFail(null);
    try {
      await fn();
    } catch (e) {
      setFail(codeOf(e));
    } finally {
      setBusy(false);
    }
  };

  const header = (
    <div className="acc-profile">
      <div className="acc-avatar big off" aria-hidden="true"><Globe size={26} strokeWidth={1.6} /></div>
      <div className="acc-text"><div className="label">{t('online.title')}</div></div>
    </div>
  );
  const errorLine = (code: OnlineErrorCode | null) => code && <p className="acc-error" role="alert">{t(`online.err.${code}`)}</p>;

  if (!onlineConfigured) {
    return (
      <div className="acc-card">
        {header}
        <p className="hint">{t('online.notConfigured')}</p>
      </div>
    );
  }

  if (status === 'idle' || status === 'connecting') {
    return (
      <div className="acc-card">
        {header}
        <p className="hint" role="status">{t('online.connecting')}</p>
      </div>
    );
  }

  if (status === 'error') {
    const expired = error === 'sessionExpired' || error === 'notSignedIn';
    return (
      <div className="acc-card">
        {header}
        {errorLine(error)}
        <div className="acc-actions">
          {expired ? (
            <button className="btn btn-sm" disabled={busy} onClick={() => void run(async () => void (await signIn()))}>
              <RefreshCw size={16} aria-hidden="true" />{t('online.reconnect')}
            </button>
          ) : (
            <button className="btn btn-sm" onClick={() => void connect()}>
              <RefreshCw size={16} aria-hidden="true" />{t('online.retry')}
            </button>
          )}
        </div>
      </div>
    );
  }

  /* ---- signed in, no public profile yet ---- */
  if (!profile) {
    const canCreate = handleOk && name.trim().length > 0 && !busy;
    return (
      <form className="acc-card online-form" onSubmit={(e) => {
        e.preventDefault();
        if (!canCreate) return;
        void run(async () => {
          setProfile(await createProfile(handle, name, bio));
          toast('online.created', 'success');
        });
      }}>
        {header}
        <div className="acc-text">
          <div className="label">{t('online.createTitle')}</div>
          <p className="hint">{t('online.createHint')}</p>
        </div>
        <HandleField value={handle} onChange={setHandle} onState={setHandleOk} />
        <div>
          <label className="online-label" htmlFor="online-name">{t('online.displayName')}</label>
          <input id="online-name" className="name-input" style={{ width: '100%' }} value={name} maxLength={60} onChange={(e) => setName(e.target.value)} />
        </div>
        <div>
          <label className="online-label" htmlFor="online-bio">{t('online.bio')}</label>
          <textarea id="online-bio" className="textarea" value={bio} maxLength={300} onChange={(e) => setBio(e.target.value)} />
        </div>
        {errorLine(fail)}
        <div className="acc-actions"><button className="btn btn-primary" type="submit" disabled={!canCreate}>{busy ? '…' : t('online.create')}</button></div>
      </form>
    );
  }

  /* ---- profile exists ---- */
  const startEdit = () => {
    setName(profile.display_name);
    setBio(profile.bio);
    setHandle('');
    setHandleOk(false);
    setFail(null);
    setEditing(true);
  };
  const wantsHandle = normalizeHandle(handle) !== '' && normalizeHandle(handle) !== profile.handle;
  const canSave = !busy && name.trim().length > 0 && (!wantsHandle || handleOk);

  return (
    <div className="acc-card online-form">
      <div className="acc-profile">
        <div className="acc-avatar big" aria-hidden="true">{profile.display_name.trim().charAt(0).toUpperCase()}</div>
        <div className="acc-text">
          <div className="label" dir="auto">{profile.display_name}</div>
          <div className="hint" dir="ltr">@{profile.handle}</div>
          {profile.bio && <p className="hint" dir="auto">{profile.bio}</p>}
        </div>
      </div>

      {editing ? (
        <form className="online-form" onSubmit={(e) => {
          e.preventDefault();
          if (!canSave) return;
          void run(async () => {
            let next = profile;
            if (wantsHandle) {
              next = await changeHandle(handle);
              toast('online.handleChanged', 'success');
            }
            if (name.trim() !== next.display_name || bio.trim() !== next.bio) {
              next = await updateMyProfile(name, bio);
              toast('online.saved', 'success');
            }
            setProfile(next);
            setEditing(false);
          });
        }}>
          <div>
            <label className="online-label" htmlFor="online-name">{t('online.displayName')}</label>
            <input id="online-name" className="name-input" style={{ width: '100%' }} value={name} maxLength={60} onChange={(e) => setName(e.target.value)} />
          </div>
          <div>
            <label className="online-label" htmlFor="online-bio">{t('online.bio')}</label>
            <textarea id="online-bio" className="textarea" value={bio} maxLength={300} onChange={(e) => setBio(e.target.value)} />
          </div>
          <HandleField value={handle} onChange={setHandle} current={profile.handle} onState={setHandleOk} />
          <p className="hint">{t('online.handleCooldownHint')}</p>
          {errorLine(fail)}
          <div className="acc-actions">
            <button className="btn btn-primary btn-sm" type="submit" disabled={!canSave}>{busy ? '…' : t('online.save')}</button>
            <button className="btn btn-ghost btn-sm" type="button" onClick={() => setEditing(false)}>{t('common.cancel')}</button>
          </div>
        </form>
      ) : (
        <>
          <p className="hint">{t('online.publicNote')}</p>
          {errorLine(fail)}
          <div className="acc-actions">
            <button className="btn btn-sm btn-primary" onClick={() => useApp.getState().navigate({ name: 'onlineLibrary' })}>
              <Library size={16} aria-hidden="true" />{t('onlineLib.open')}
            </button>
            <button className="btn btn-sm" onClick={() => setVisiting(true)}><Search size={16} aria-hidden="true" />{t('visit.open')}</button>
            <button className="btn btn-sm" onClick={startEdit}>{t('online.edit')}</button>
            <button className="btn btn-sm btn-ghost btn-danger" onClick={() => setConfirmDelete(true)}>
              <Trash2 size={16} aria-hidden="true" />{t('online.delete')}
            </button>
          </div>
        </>
      )}

      {visiting && <VisitSheet onClose={() => setVisiting(false)} />}
      {confirmDelete && (
        <ConfirmDialog
          danger
          title={t('online.deleteTitle')}
          body={t('online.deleteBody')}
          confirmLabel={t('online.deleteConfirm')}
          onCancel={() => setConfirmDelete(false)}
          onConfirm={() => {
            setConfirmDelete(false);
            void run(async () => {
              await deleteOnlineAccount();
              await reset();
              toast('online.deleted', 'info');
            });
          }}
        />
      )}
    </div>
  );
}
