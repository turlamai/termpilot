import { useApp } from '../state/store';
import { useFeedback } from '../state/feedback';
import { Icon } from './Icon';

// Renders the in-app confirm dialog and the toast region. Mounted once,
// at the app root.

export default function FeedbackLayer() {
  const lang = useApp((s) => s.lang);
  const open = useFeedback((s) => s.open);
  const message = useFeedback((s) => s.message);
  const danger = useFeedback((s) => s.danger);
  const confirmLabel = useFeedback((s) => s.confirmLabel);
  const answer = useFeedback((s) => s.answer);
  const toasts = useFeedback((s) => s.toasts);
  const dismiss = useFeedback((s) => s.dismiss);

  const okLabel = confirmLabel || (lang === 'zh' ? '确定' : 'OK');
  const cancelLabel = lang === 'zh' ? '取消' : 'Cancel';

  return (
    <>
      {open && (
        <div className="modal-backdrop" onClick={() => answer(false)}>
          <div
            className="modal confirm-box"
            onClick={(e) => e.stopPropagation()}
            role="alertdialog"
            aria-modal="true"
          >
            <p>{message}</p>
            <div className="modal-actions">
              <span className="spacer" />
              <button className="btn" onClick={() => answer(false)}>
                {cancelLabel}
              </button>
              <button
                className={`btn ${danger ? 'btn-danger' : 'btn-primary'}`}
                autoFocus
                onClick={() => answer(true)}
              >
                {okLabel}
              </button>
            </div>
          </div>
        </div>
      )}
      <div className="toast-region">
        {toasts.map((t) => (
          <div
            key={t.id}
            className={`toast ${t.error ? 'error' : ''}`}
            onClick={() => dismiss(t.id)}
          >
            {!t.error && <Icon name="circle-dot" size={13} />} {t.text}
          </div>
        ))}
      </div>
    </>
  );
}
