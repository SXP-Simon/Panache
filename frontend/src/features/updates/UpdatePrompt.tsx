import { useState } from 'react';
import { useI18n } from '@/i18n';
import Button from '@/shared/ui/Button';
import Modal from '@/shared/ui/Modal';
import { updateAction, useUpdateState } from './runtime';
import { useUpdatesStore } from './store';
import type { UpdatePrompt as UpdatePromptData } from './store';
import { summarizeReleaseNotes } from './releaseSummary';
import { updateMessage } from './presentation';
export default function UpdatePrompt({ prompt }: { prompt: UpdatePromptData }) {
  const { t } = useI18n();
  const state = useUpdateState();
  const [acting, setActing] = useState(false);
  const desktop = Boolean(window.handwritingDesktop);
  const shown = state.version === prompt.update.version ? state : prompt.update;
  const notes = desktop ? summarizeReleaseNotes(prompt.update.notes ?? '') : [];
  const busy = acting || shown.status === 'downloading' || shown.status === 'checking';
  const ready = ['ready', 'launched'].includes(shown.status);
  const canUpdate = ['available', 'cancelled', 'ready', 'launched'].includes(shown.status);
  const dismiss = () => useUpdatesStore.getState().dismissPrompt();
  const act = async () => {
    setActing(true);
    const action = !desktop || ready ? 'open' : 'download';
    await updateAction(action);
    if (action === 'open' && useUpdatesStore.getState().update.status !== 'error') dismiss();
    setActing(false);
  };
  return (
    <Modal
      title={t(desktop ? 'updatePromptTitle' : 'updateWebPromptTitle')}
      closeLabel={t('close')}
      testId="update-prompt"
      onClose={dismiss}
    >
      {desktop ? (
        <p className="update-prompt-version" data-testid="update-prompt-version">
          Panache {prompt.update.version ? `v${prompt.update.version}` : ''}
        </p>
      ) : (
        <p className="help-text">{t('updateWebPromptHint')}</p>
      )}
      {notes.length > 0 ? (
        <section
          className="update-prompt-notes"
          aria-label={t('updateNotes')}
          data-testid="update-prompt-notes"
        >
          <h3>{t('updateNotes')}</h3>
          <ul>
            {notes.map((note) => (
              <li key={note}>{note}</li>
            ))}
          </ul>
        </section>
      ) : desktop ? (
        <p className="help-text">{t('updatePromptNoNotes')}</p>
      ) : null}
      {shown.status !== 'available' && (
        <p role="status" data-testid="update-prompt-status">
          {t(updateMessage(shown))}
        </p>
      )}
      {shown.status === 'downloading' && (
        <progress
          className="update-prompt-progress"
          value={shown.bytes ?? 0}
          max={shown.total ?? 1}
          aria-label={t('updateDownloading')}
        />
      )}
      {prompt.update.releaseUrl && (
        <a
          className="project-source-link"
          href={prompt.update.releaseUrl}
          target="_blank"
          rel="noopener noreferrer"
        >
          {t('updateFullNotes')}
        </a>
      )}
      <footer className="modal-actions">
        <Button variant="ghost" data-testid="update-prompt-later" onClick={dismiss}>
          {t('updateLater')}
        </Button>
        {shown.status === 'downloading' ? (
          <Button
            variant="secondary"
            data-testid="update-prompt-cancel"
            onClick={() => {
              void updateAction('cancel');
            }}
          >
            {t('cancel')}
          </Button>
        ) : (
          <Button
            variant="primary"
            data-testid="update-prompt-now"
            disabled={busy || !canUpdate}
            onClick={() => {
              void act();
            }}
          >
            {t(
              !desktop
                ? 'updateReload'
                : ready
                  ? shown.portable
                    ? 'updateReveal'
                    : 'updateOpen'
                  : 'updateNow',
            )}
          </Button>
        )}
      </footer>
    </Modal>
  );
}
