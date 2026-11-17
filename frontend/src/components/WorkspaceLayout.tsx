import { useRef, useState } from 'react';
import { useDocumentStore } from '@/features/document/store';
import { usePreviewStore } from '@/features/preview/store';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import { useI18n } from '@/i18n';
import { SlidersHorizontal } from '@/shared/icons';
import Button from '@/shared/ui/Button';
import EditorPanel from './EditorPanel';
import GenerateButton from './GenerateButton';
import PreviewPanel from './PreviewPanel';
import SettingsPanel from './SettingsPanel';
import WorkspaceFooter from './WorkspaceFooter';
import WorkspaceStatus from './WorkspaceStatus';

const narrowViewport = '(max-width: 720px)';
const panes = [
  { id: 'edit', label: 'workspaceEdit' },
  { id: 'paper', label: 'workspacePaper' },
  { id: 'preview', label: 'workspacePreview' },
] as const;
type Pane = (typeof panes)[number]['id'];

export default function WorkspaceLayout({ openAppearance }: { openAppearance: () => void }) {
  const { t } = useI18n();
  const { generate } = useWorkspaceActions();
  const [pane, setPane] = useState<Pane>('edit');
  const navigation = useRef(0);

  function selectPane(next: Pane) {
    navigation.current += 1;
    setPane(next);
    window.scrollTo(0, 0);
  }

  async function generatePreview() {
    const narrow = window.matchMedia(narrowViewport);
    const revision = navigation.current;
    const draft = useDocumentStore.getState();
    const previous = usePreviewStore.getState().images;
    await generate('preview');
    const images = usePreviewStore.getState().images;
    const editing = document.activeElement?.closest(
      'input, textarea, select, [contenteditable], dialog',
    );
    if (
      narrow.matches &&
      navigation.current === revision &&
      useDocumentStore.getState() === draft &&
      images !== previous &&
      images.length &&
      !editing
    ) {
      selectPane('preview');
    }
  }

  return (
    <>
      <div className="workspace-actions">
        <Button
          className="mobile-settings-button"
          variant="ghost"
          data-testid="mobile-settings-btn"
          onClick={openAppearance}
        >
          <SlidersHorizontal size={16} />
          {t('appearance')}
        </Button>
        <GenerateButton testId="preview-btn" onGenerate={() => void generatePreview()} />
      </div>
      <nav className="mobile-workspace-nav" aria-label={t('workspace')}>
        {panes.map(({ id, label }) => (
          <Button
            key={id}
            variant="ghost"
            data-testid={`workspace-pane-${id}`}
            aria-pressed={pane === id}
            aria-controls={`workspace-panel-${id}`}
            onClick={() => selectPane(id)}
          >
            {t(label)}
          </Button>
        ))}
      </nav>
      <WorkspaceStatus />
      <div className="workspace-grid" data-pane={pane} data-testid="workspace">
        <EditorPanel />
        <PreviewPanel />
        <SettingsPanel />
      </div>
      <WorkspaceFooter />
    </>
  );
}
