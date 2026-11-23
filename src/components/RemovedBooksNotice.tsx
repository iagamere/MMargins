import { useEffect, useState } from 'react';
import { fetchRemovedBooks, type RemovedBook } from '../lib/online';
import { useT } from '../lib/i18n';

/** shown to the owner only, and only when a moderator removed one of her books after a report */
export function RemovedBooksNotice() {
  const { t } = useT();
  const [items, setItems] = useState<RemovedBook[]>([]);
  useEffect(() => {
    let live = true;
    fetchRemovedBooks().then((r) => { if (live) setItems(r); }).catch(() => undefined);
    return () => { live = false; };
  }, []);
  if (items.length === 0) return null;
  return (
    <div className="acc-card" style={{ marginBottom: 12 }}>
      <div className="label">{t('report.removedTitle')}</div>
      <p className="hint">{t('report.removedBody')}</p>
      <ul className="olib-list">
        {items.map((b) => (
          <li key={b.book_id} className="olib-row"><div className="olib-main"><div className="label" dir="auto">{b.title}</div><div className="hint">{t(`report.reason.${b.reason}`)}</div></div></li>
        ))}
      </ul>
    </div>
  );
}
