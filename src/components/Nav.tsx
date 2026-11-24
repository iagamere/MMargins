import { BookOpen, House, Library, Settings as Cog, UserRound, type LucideIcon } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { isNative } from '../lib/platform';
import { LogoMark } from './Logo';

/** Order on the phone, left to right: On device · Continue · [Home] · Account · Settings. */
const items = [
  { name: 'library', icon: Library, label: 'nav.library' },
  { name: 'continue', icon: BookOpen, label: 'nav.continue' },
  { name: 'home', icon: House, label: 'nav.home' },
  { name: 'onlineLibrary', icon: UserRound, label: 'nav.me' },
  { name: 'settings', icon: Cog, label: 'nav.settings' },
] as const;

/** Which tab a route belongs to. */
function active(route: string) {
  switch (route) {
    case 'details':
      return 'library';
    case 'discover':
    case 'visit':
      return 'home';
    case 'people':
    case 'notifications':
    case 'moderation':
      return 'onlineLibrary';
    case 'account':
      return 'settings';
    default:
      return route;
  }
}

/** Home circle: sits in the middle of the bottom bar and rises above it. Opens the online side (libraries, discovery). */
function HomeFab() {
  const { t } = useT();
  const route = useApp((s) => s.route);
  const navigate = useApp((s) => s.navigate);
  const label = t('nav.home');
  return (
    <div className="nav-fab-slot">
      <button className="nav-fab" aria-current={active(route.name) === 'home' ? 'page' : undefined} onClick={() => navigate({ name: 'home' }, { replace: true })} aria-label={label} title={label}>
        <span className="acc-avatar" aria-hidden="true"><House size={22} strokeWidth={1.8} /></span>
      </button>
    </div>
  );
}

export function BottomNav() {
  const route = useApp((s) => s.route);
  const account = useApp((s) => s.account);
  const busy = useApp((s) => s.syncing || Object.keys(s.transfers).length > 0);
  const navigate = useApp((s) => s.navigate);
  const { t } = useT();
  const go = (name: string) => navigate({ name } as any, { replace: true });
  const item = (name: string, Icon: LucideIcon, label: string) => (
    <button key={name} className="nav-item" aria-current={active(route.name) === name ? 'page' : undefined} onClick={() => go(name)}>
      <Icon size={22} aria-hidden="true" />
      <span>{t(label)}</span>
      {/* signed in: green dot on Settings (pulses while books are syncing) */}
      {name === 'settings' && account && <i className={'nav-dot' + (busy ? ' busy' : '')} aria-hidden="true" />}
    </button>
  );
  // on the phone app: two tabs, the Home circle, two tabs (balanced around the circle)
  if (isNative) {
    return (
      <nav className="nav has-fab" aria-label={t('nav.main')}>
        {item('library', Library, 'nav.library')}
        {item('continue', BookOpen, 'nav.continue')}
        <HomeFab />
        {item('onlineLibrary', UserRound, 'nav.me')}
        {item('settings', Cog, 'nav.settings')}
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
