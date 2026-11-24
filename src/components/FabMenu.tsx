import { useEffect, useState } from 'react';
import type { LucideIcon } from 'lucide-react';
import { Plus, X } from 'lucide-react';
import { useT } from '../lib/i18n';

export interface FabAction {
  id: string;
  icon: LucideIcon;
  label: string;
  onClick(): void;
  /** shown but not usable (feature not built yet) */
  disabled?: boolean;
}

/** One round "+" floating on the side. Tapping it fans out smaller round buttons, one per action. */
export function FabMenu({ actions }: { actions: FabAction[] }) {
  const { t } = useT();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  // a single action needs no menu: the circle does it directly
  if (actions.length === 1) {
    const a = actions[0];
    return (
      <div className="fabm">
        <button className="fabm-main" onClick={a.onClick} aria-label={a.label} title={a.label}>
          <Plus size={26} aria-hidden="true" />
        </button>
      </div>
    );
  }

  return (
    <>
      {open && <div className="fabm-scrim" onClick={() => setOpen(false)} aria-hidden="true" />}
      <div className={'fabm' + (open ? ' open' : '')}>
        {open && (
          <ul className="fabm-list">
            {actions.map((a, i) => (
              <li key={a.id} style={{ animationDelay: `${(actions.length - 1 - i) * 40}ms` }}>
                <span className="fabm-label">{a.label}</span>
                <button
                  className="fabm-sub"
                  disabled={a.disabled}
                  aria-label={a.label}
                  title={a.label}
                  onClick={() => { setOpen(false); a.onClick(); }}
                >
                  <a.icon size={20} aria-hidden="true" />
                </button>
              </li>
            ))}
          </ul>
        )}
        <button className="fabm-main" onClick={() => setOpen((v) => !v)} aria-expanded={open} aria-label={open ? t('fab.close') : t('fab.add')} title={open ? t('fab.close') : t('fab.add')}>
          {open ? <X size={26} aria-hidden="true" /> : <Plus size={26} aria-hidden="true" />}
        </button>
      </div>
    </>
  );
}
