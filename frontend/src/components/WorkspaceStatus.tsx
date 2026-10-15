import { useSyncExternalStore } from 'react';
import { AnimatePresence } from 'motion/react';
import { useShallow } from 'zustand/react/shallow';
import { useGenerationState } from '@/features/generation/state';
import { useNotificationStore } from '@/features/notifications/store';
import type { Notice } from '@/features/notifications/store';
import { usePreviewStore } from '@/features/preview/store';
import { getPwaState, subscribePwa } from '@/pwa';
import { useI18n } from '@/i18n';
import type { MessageKey } from '@/i18n';
import { AlertCircle, LoaderCircle, Check, FolderOpen } from '@/shared/icons';
import AnimatedReveal from '@/shared/ui/AnimatedReveal';
import Button from '@/shared/ui/Button';

function noticeText(notice: Notice | null, translate: (key: MessageKey) => string): string {
  return notice ? ('key' in notice ? translate(notice.key) : notice.text) : '';
}
export default function WorkspaceStatus() {
  const { t } = useI18n();
  const pwa = useSyncExternalStore(subscribePwa, getPwaState);
  const { notice, error } = useNotificationStore(
    useShallow((state) => ({ notice: state.notice, error: state.error })),
  );
  const generation = useGenerationState();
  const savedPath = usePreviewStore((state) => state.savedPath);
  const pdfBytes = usePreviewStore((state) => state.pdfBytes);
  const task = generation.task;
  const details =
    task?.task_status === 'pending'
      ? [
          typeof task.queue_ahead_count === 'number'
            ? `${t('queueAhead')} ${task.queue_ahead_count}`
            : '',
          typeof task.queue_pending_count === 'number'
            ? `${t('queuePending')} ${task.queue_pending_count}`
            : '',
          typeof task.processing_count === 'number'
            ? `${t('queueProcessing')} ${task.processing_count}`
            : '',
        ].filter(Boolean)
      : [];
  const serverError = generation.error;
  const serverFailure =
    serverError && serverError.code !== 'queueFull' && serverError.code !== 'cancelled'
      ? (serverError.serverMessage ?? t(serverError.code))
      : '';
  const status =
    noticeText(error, t) ||
    (generation.retrySeconds > 0
      ? `${t('queueBusy')} ${generation.retrySeconds} ${t('queueSuffix')}`
      : generation.busy
        ? [task?.task_message || t('working'), ...details].join(' · ')
        : noticeText(notice, t) || serverFailure);
  const failed = Boolean(error || (!generation.busy && !notice && serverFailure));
  return (
    <>
      <AnimatePresence initial={false}>
        {!pwa.online && (
          <AnimatedReveal key="offline">
            <div className="status-message" role="status" data-testid="offline-notice">
              <AlertCircle size={17} />
              <span>{t('offlineNotice')}</span>
            </div>
          </AnimatedReveal>
        )}
        {status && (
          <AnimatedReveal key="status">
            <div
              className={`status-message ${failed ? 'status-message--error' : ''}`}
              role="status"
              aria-live="polite"
              data-testid="message-info"
            >
              {failed ? (
                <AlertCircle size={17} />
              ) : generation.busy ? (
                <LoaderCircle className="spin" size={17} />
              ) : (
                <Check size={17} />
              )}
              <span>{status}</span>
            </div>
          </AnimatedReveal>
        )}
        {savedPath && (
          <AnimatedReveal key="download">
            <div className="download-hint" data-testid="download-saved-hint">
              <span data-testid="download-saved-path">{savedPath}</span>
              <Button
                size="small"
                variant="ghost"
                data-testid="reveal-download-btn"
                onClick={() => window.handwritingDesktop?.revealLastDownload()}
              >
                <FolderOpen size={15} />
                {t('openFolder')}
              </Button>
            </div>
          </AnimatedReveal>
        )}
      </AnimatePresence>
      {pdfBytes > 0 && (
        <span data-testid="pdf-download-bytes" hidden>
          {pdfBytes}
        </span>
      )}
    </>
  );
}
