import { useState } from 'react';
import { Globe, KeyRound, Lock, Settings2, Users, type LucideIcon } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { ACCESS_MODES, type AccessMode, type ShelfAccess } from '../lib/access';
import { OnlineError, removeAccessPassword, revokeAccessGrants, type ProtectedType } from '../lib/online';
import { ConfirmDialog } from './ConfirmDialog';

export const ACCESS_ICONS: Record<AccessMode, LucideIcon> = { public: Globe, password: KeyRound, friends: Users, private: Lock };
export const codeOf = (e: unknown) => (e instanceof OnlineError ? e.code : 'unknown');

export function AccessBadge({ mode, inherited }: { mode: AccessMode; inherited?: boolean }) {
  const { t } = useT();
  const Icon = ACCESS_ICONS[mode];
  return (
    <span className={'olib-badge ' + mode}>
      <Icon size={14} aria-hidden="true" />
      {t(`onlineLib.access.${mode}`)}
      {inherited && <span className="olib-inh"> · {t('onlineLib.inherited')}</span>}
    </span>
  );
}

/** radio list of access modes, optionally with a leading "same as library" choice */
export function AccessPicker({ value, onChange, allowInherit, libraryDefault, label, inheritKey }: { value: ShelfAccess; onChange: (v: ShelfAccess) => void; allowInherit?: boolean; libraryDefault?: AccessMode; label: string; inheritKey?: string }) {
  const { t } = useT();
  const opts: ShelfAccess[] = allowInherit ? ['inherit', ...ACCESS_MODES] : ACCESS_MODES;
  return (
    <fieldset className="olib-picker">
      <legend className="online-label">{label}</legend>
      {opts.map((m) => {
        const on = value === m;
        const Icon = m === 'inherit' ? Settings2 : ACCESS_ICONS[m];
        return (
          <label key={m} className={'olib-opt' + (on ? ' on' : '')}>
            <input type="radio" name="access" checked={on} onChange={() => onChange(m)} />
            <Icon size={18} aria-hidden="true" />
            <span className="olib-opt-text">
              <span className="olib-opt-title">
                {m === 'inherit' ? t('onlineLib.access.inherit') : t(`onlineLib.access.${m}`)}
                {m === 'inherit' && libraryDefault && <> ({t(`onlineLib.access.${libraryDefault}`)})</>}
              </span>
              <span className="hint">{t(m === 'inherit' ? (inheritKey ?? 'onlineLib.access.inherit.desc') : `onlineLib.access.${m}.desc`)}</span>
            </span>
          </label>
        );
      })}
    </fieldset>
  );
}

/** password block shown while the password mode is selected */
export function PasswordBlock({ type, id, mode, value, onChange, has, setHas }: { type: ProtectedType; id: string; mode: ShelfAccess; value: string; onChange: (v: string) => void; has: boolean | null; setHas: (v: boolean) => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const act = async (fn: () => Promise<void>, ok: string) => {
    setBusy(true);
    setErr(null);
    try {
      await fn();
      toast(ok, 'success');
    } catch (e) {
      setErr(codeOf(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="olib-pw">
      <label className="online-label" htmlFor={`pw-${id}`}>{has ? t('onlineLib.passwordChange') : t('onlineLib.passwordNew')}</label>
      <input id={`pw-${id}`} type="password" className="name-input" style={{ width: '100%' }} dir="ltr" autoComplete="new-password" minLength={8} maxLength={128} value={value} onChange={(e) => onChange(e.target.value)} />
      <p className="hint">{has === null ? '' : has ? t('onlineLib.passwordSet') : mode === 'password' ? t('onlineLib.passwordNone') : ''} {t('onlineLib.passwordRule')}</p>
      {err && <p className="acc-error" role="alert">{t(`online.err.${err}`)}</p>}
      {has && (
        <div className="acc-actions">
          <button type="button" className="btn btn-sm btn-ghost" disabled={busy} onClick={() => void act(() => revokeAccessGrants(type, id), 'onlineLib.revoked')}>{t('onlineLib.revoke')}</button>
          <button type="button" className="btn btn-sm btn-ghost btn-danger" disabled={busy} onClick={() => void act(async () => { await removeAccessPassword(type, id); setHas(false); }, 'onlineLib.passwordRemoved')}>{t('onlineLib.passwordRemove')}</button>
        </div>
      )}
    </div>
  );
}

export function PublicConfirm({ onConfirm, onCancel }: { onConfirm: () => void; onCancel: () => void }) {
  const { t } = useT();
  return <ConfirmDialog title={t('onlineLib.publicTitle')} body={t('onlineLib.publicBody')} confirmLabel={t('onlineLib.publicConfirm')} onConfirm={onConfirm} onCancel={onCancel} />;
}

