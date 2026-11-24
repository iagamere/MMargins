import { useEffect } from 'react';
import { Bell, Cloud } from 'lucide-react';
import { useApp } from '../store/useApp';
import { useInbox } from '../store/useInbox';
import { useT } from '../lib/i18n';
import { onlineConfigured } from '../lib/online';
import { DiscoverScreen } from './Discover';

/** The online side in one place: browse books, libraries, shelves and posts. Needs a signed-in account; reading offline never does. */
export function HomeScreen() {
  const { t } = useT();
  const account = useApp((s) => s.account);
  const navigate = useApp((s) => s.navigate);
  const unread = useInbox((s) => s.unread);
  useEffect(() => { if (account && onlineConfigured) void useInbox.getState().refresh(); }, [account]);

  if (!account) {
    return (
      <div className="screen">
        <div className="screen-pad" style={{ maxWidth: 720 }}>
          <header className="page-head"><div className="top"><h1 className="h-display">{t('home.title')}</h1></div></header>
          <div className="acc-card">
            <div className="acc-avatar big off" aria-hidden="true"><Cloud size={26} strokeWidth={1.6} /></div>
            <div className="acc-text"><p className="hint">{t('home.signInHint')}</p></div>
            <button className="btn btn-primary" onClick={() => navigate({ name: 'account' })}>{t('account.signInBtn')}</button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="screen">
      <div className="screen-pad" style={{ maxWidth: 720 }}>
        <header className="page-head">
          <div className="top">
            <h1 className="h-display">{t('home.title')}</h1>
            {onlineConfigured && (
              <div className="row top-actions">
                <button className="icon-btn" onClick={() => navigate({ name: 'notifications' })} aria-label={t('notif.open')} title={t('notif.open')} style={{ position: 'relative' }}>
                  <Bell size={21} />
                  {unread > 0 && <span className="count-dot" aria-label={String(unread)}>{unread}</span>}
                </button>
              </div>
            )}
          </div>
        </header>
      </div>
      <DiscoverScreen embedded />
    </div>
  );
}
