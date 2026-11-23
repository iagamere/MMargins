import { useState } from 'react';
import { REPORT_REASONS, reportContent, type ReportReason, type ReportTarget } from '../lib/online';
import { useApp } from '../store/useApp';
import { useT } from '../lib/i18n';
import { Sheet } from './Sheet';
import { codeOf } from './AccessControls';

/** Files a report about something the reader can see. The database refuses anything else. */
export function ReportSheet({ type, id, label, onClose }: { type: ReportTarget; id: string; label: string; onClose: () => void }) {
  const { t } = useT();
  const toast = useApp((s) => s.toast);
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [details, setDetails] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const send = async () => {
    if (!reason || busy) return;
    setBusy(true);
    setErr(null);
    try {
      await reportContent(type, id, reason, details);
      toast('report.sent', 'success');
      onClose();
    } catch (e) {
      setErr(`online.err.${codeOf(e)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title={t('report.title')} onClose={onClose}>
      <p className="label" dir="auto" style={{ marginBottom: 10 }}>{label}</p>
      <div className="label" style={{ marginBottom: 8 }}>{t('report.reasonLabel')}</div>
      <div className="chips" role="group" aria-label={t('report.reasonLabel')} style={{ flexWrap: 'wrap' }}>
        {REPORT_REASONS.map((r) => (
          <button key={r} className="chip" aria-pressed={reason === r} onClick={() => setReason(r)}>{t(`report.reason.${r}`)}</button>
        ))}
      </div>
      <div className="label" style={{ margin: '16px 0 8px' }}>{t('report.details')}</div>
      <textarea className="textarea" dir="auto" maxLength={1000} value={details} placeholder={t('report.detailsPlaceholder')} onChange={(e) => setDetails(e.target.value)} />
      <p className="hint" style={{ marginTop: 10 }}>{t('report.note')}</p>
      {err && <p className="acc-error" role="alert">{t(err)}</p>}
      <div className="acc-actions" style={{ marginTop: 14 }}>
        <button className="btn btn-primary" disabled={!reason || busy} onClick={() => void send()}>{busy ? '…' : t('report.send')}</button>
      </div>
    </Sheet>
  );
}
