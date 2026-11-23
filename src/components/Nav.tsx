import { BookOpen, Globe, Library, Settings as Cog, UserRound } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { isNative } from '../lib/platform';
import { LogoMark } from './Logo';

const items = [
  { name: 'library', icon: Library, label: 'nav.library' },
  { name: 'continue', icon: BookOpen, label: 'nav.continue' },
  { name: 'settings', icon: Cog, label: 'nav.settings' },
] as const;

function active(route: string) {
  return route === 'details' ? 'library' : route === 'visit' || route === 'discover' ? 'onlineLibrary' : route;
}

/** Account circle: sits in the middle of the bottom bar and rises above it. Initial of the signed-in user + a sync dot (green = in sync, pulsing = moving books). */
function AccountFab() {
  const { t } = useT();
  const account = useApp((s) => s.account);
  const route = useApp((s) => s.route);
  const busy = useApp((s) => s.syncing || Object.keys(s.transfers).length > 0);
  const navigate = useApp((s) => s.navigate);
  const initial = account ? (account.name || account.email || '?').trim().charAt(0).toUpperCase() : '';
  const label = account ? `${t('account.title')}: ${account.name || account.email}` : t('account.signIn');
  return (
    <div className="nav-fab-slot">
      <button className="nav-fab" aria-current={route.name === 'account' ? 'page' : undefined} onClick={() => navigate({ name: 'account' })} aria-label={label} title={label}>
        <span className={'acc-avatar' + (account ? '' : ' off')} aria-hidden="true">{account ? initial : <UserRound size={22} strokeWidth={1.8} />}</span>
        {account && <i className={'acc-dot' + (busy ? ' busy' : '')} aria-hidden="true" />}
      </button>
    </div>
  );
}

export function BottomNav() {
  const route = useApp((s) => s.route);
  const account = useApp((s) => s.account);
  const navigate = useApp((s) => s.navigate);
  const { t } = useT();
  const go = (name: string) => navigate({ name } as any, { replace: true });
  const item = (name: string, Icon: typeof Library, label: string, target = name) => (
    <button key={name} className="nav-item" aria-current={active(route.name) === name ? 'page' : undefined} onClick={() => go(target)}>
      <Icon size={22} aria-hidden="true" />
      <span>{t(label)}</span>
    </button>
  );
  // on the phone app: two tabs, the account circle, two tabs (balanced around the circle)
  if (isNative) {
    return (
      <nav className="nav has-fab" aria-label={t('nav.main')}>
        {item('library', Library, 'nav.library')}
        {item('continue', BookOpen, 'nav.continue')}
        <AccountFab />
        {item('settings', Cog, 'nav.settings')}
        {item('onlineLibrary', Globe, 'nav.online', account ? 'onlineLibrary' : 'account')}
      </nav>
    );
  }
  return (
    <nav className="nav" aria-label={t('nav.main')}>
      {items.map(({ name, icon, label }) => item(name, icon, label))}
    </nav>
  );
}

export function SideNav() {
  const route = useApp((s) => s.route);
  const navigate = useApp((s) => s.navigate);
  const { t } = useT();
  return (
    <aside className="side" aria-label={t('nav.main')}>
      <div className="brand">
        <LogoMark />
        <span>Margins</span>
      </div>
      {items.map(({ name, icon: Icon, label }) => (
        <button key={name} className="side-item" aria-current={active(route.name) === name ? 'page' : undefined} onClick={() => navigate({ name } as any, { replace: true })}>
          <Icon size={20} aria-hidden="true" />
          <span>{t(label)}</span>
        </button>
      ))}
      <div className="side-foot">{t('app.tagline')}</div>
    </aside>
  );
}
