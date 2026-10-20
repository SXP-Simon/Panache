import { useI18n } from '@/i18n';
import { usePreferencesStore } from '@/features/preferences/store';
import Button from '@/shared/ui/Button';
import { checkUpdates, showUpdatePrompt, updateAction, useUpdateState } from './runtime';
import { updateMessage } from './presentation';
import { summarizeReleaseNotes } from './releaseSummary';
export default function UpdateSettings() {
  const { t } = useI18n();
  const state = useUpdateState();
  const auto = usePreferencesStore((value) => value.autoCheckUpdates);
  const patch = usePreferencesStore((value) => value.patch);
  const desktop = Boolean(window.handwritingDesktop);
  const notes = summarizeReleaseNotes(state.notes ?? '');
  const busy = state.status === 'checking' || state.status === 'downloading';
  const message = updateMessage(state);
  return (
    <section className="update-settings" data-testid="update-settings">
      <h3>{t('updates')}</h3>
      {!desktop && <p className="help-text">{t('updateWebHint')}</p>}
      <label className="update-auto">
        <input
          data-testid="update-auto"
          type="checkbox"
          title={t('updateAutoHint')}
          checked={auto}
          onChange={(event) => patch({ autoCheckUpdates: event.target.checked })}
        />
        {t('updateAuto')}
      </label>
      {state.current && (
        <p>
          {t('updateInstalledVersion')} {state.current}
        </p>
      )}
      <p role="status" data-testid="update-status">
        {t(message)}
        {state.version ? ` · v${state.version}` : ''}
      </p>
      {state.status === 'downloading' && (
        <div>
          <progress data-testid="update-progress" value={state.bytes ?? 0} max={state.total ?? 1} />
          <span> {Math.floor(((state.bytes ?? 0) / (state.total ?? 1)) * 100)}%</span>
        </div>
      )}
      <div className="appearance-tools">
        <Button
          variant="secondary"
          data-testid="update-check"
          disabled={busy}
          onClick={() => {
            void checkUpdates();
          }}
        >
          {t('updateCheck')}
        </Button>
        {['available', 'downloading', 'ready', 'launched', 'cancelled'].includes(state.status) && (
          <Button
            variant="ghost"
            data-testid="update-show-prompt"
            onClick={() => showUpdatePrompt()}
          >
            {t('updateShowPrompt')}
          </Button>
        )}
        {desktop && ['available', 'cancelled'].includes(state.status) && (
          <Button
            variant="primary"
            data-testid="update-download"
            onClick={() => {
              void updateAction('download');
            }}
          >
            {t('updateDownload')}
          </Button>
        )}
        {state.status === 'downloading' && (
          <Button
            variant="ghost"
            data-testid="update-cancel"
            onClick={() => {
              void updateAction('cancel');
            }}
          >
            {t('cancel')}
          </Button>
        )}
        {((desktop && ['ready', 'launched'].includes(state.status)) ||
          (!desktop && state.status === 'available')) && (
          <Button
            variant="primary"
            data-testid="update-open"
            onClick={() => {
              void updateAction('open');
            }}
          >
            {t(
              !desktop
                ? 'updateReload'
                : state.portable
                  ? 'updateReveal'
                  : state.status === 'launched'
                    ? 'updateOpenAgain'
                    : 'updateOpen',
            )}
          </Button>
        )}
        {state.releaseUrl && (
          <a
            className="button button--ghost"
            href={state.releaseUrl}
            target="_blank"
            rel="noopener noreferrer"
          >
            {t('updateFullNotes')}
          </a>
        )}
      </div>
      {state.status === 'ready' && desktop && (
        <p className="help-text">
          {t(
            state.portable
              ? 'updatePortableHint'
              : /Mac/.test(navigator.platform)
                ? 'updateMacHint'
                : 'updateInstallHint',
          )}
        </p>
      )}
      {notes.length > 0 && (
        <details className="update-notes">
          <summary>{t('updateNotes')}</summary>
          <ul>
            {notes.map((note) => (
              <li key={note}>{note}</li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}
