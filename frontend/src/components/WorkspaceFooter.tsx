import { useVersionQuery } from '@/api/catalog';
import { useSaveStatus } from '@/features/workspace/saveStatus';
import { useI18n } from '@/i18n';
import { ArrowUpRight } from '@/shared/icons';

export default function WorkspaceFooter() {
  const { t } = useI18n();
  const version = useVersionQuery().data;
  const status = useSaveStatus((state) => state.status);
  return (
    <footer className="app-footer">
      <span role="status" data-testid="draft-save-status">
        <span className="local-dot" />
        {t(status === 'saving' ? 'savingDraft' : status === 'saved' ? 'savedDraft' : 'failedDraft')}
      </span>
      <a
        href="https://github.com/SXP-Simon/handwriting-web"
        target="_blank"
        rel="noopener noreferrer"
        data-testid="project-source-link"
        className="project-source-link"
      >
        {t('projectSource')}
        <ArrowUpRight size={14} aria-hidden="true" />
      </a>
      <span>
        {t('app')}
        {version && (
          <span>
            {' '}
            · <span data-testid="app-version">v{version}</span>
          </span>
        )}
      </span>
    </footer>
  );
}
