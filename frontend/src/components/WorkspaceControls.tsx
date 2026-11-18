import type { ReactNode } from 'react';
import { useI18n } from '@/i18n';
import { Eye, FileText, PenLine, Save, SlidersHorizontal, Type } from '@/shared/icons';
import Button from '@/shared/ui/Button';
import type { CanvasTool, WorkspacePane } from '@/features/workspace/useWorkspaceViewModel';
import GenerateButton from './GenerateButton';

const panes = [
  { id: 'edit', label: 'workspaceEdit' },
  { id: 'paper', label: 'workspacePaper' },
  { id: 'preview', label: 'workspacePreview' },
] as const;
const tools = [
  { id: 'edit', label: 'workspaceEdit', icon: PenLine },
  { id: 'layout', label: 'workspaceLayout', icon: Type },
  { id: 'paper', label: 'workspacePaperTool', icon: FileText },
  { id: 'ink', label: 'workspaceInk', icon: SlidersHorizontal },
  { id: 'presets', label: 'workspacePresets', icon: Save },
] as const;
const mobileTools = [...tools, { id: 'preview', label: 'workspacePreview', icon: Eye }] as const;

export function WorkspaceNavigation({
  pane,
  onSelect,
}: {
  pane: WorkspacePane;
  onSelect: (pane: WorkspacePane) => void;
}) {
  const { t } = useI18n();
  return (
    <nav className="mobile-workspace-nav" aria-label={t('workspace')}>
      {panes.map(({ id, label }) => (
        <Button
          key={id}
          variant="ghost"
          data-testid={`workspace-pane-${id}`}
          aria-pressed={pane === id}
          aria-controls={`workspace-panel-${id}`}
          onClick={() => onSelect(id)}
        >
          {t(label)}
        </Button>
      ))}
    </nav>
  );
}

export function WorkspaceToolNavigation({
  tool,
  onSelect,
  mobile = false,
}: {
  tool: CanvasTool | 'preview';
  onSelect: (tool: CanvasTool | 'preview') => void;
  mobile?: boolean;
}) {
  const { t } = useI18n();
  return (
    <nav
      className={mobile ? 'mobile-workspace-nav mobile-workspace-tools' : 'canvas-tools'}
      aria-label={t('workspace')}
      data-testid={mobile ? undefined : 'canvas-tools'}
    >
      {(mobile ? mobileTools : tools).map(({ id, label, icon: Icon }) => (
        <Button
          key={id}
          variant="ghost"
          data-testid={`${mobile ? 'workspace' : 'canvas'}-pane-${id}`}
          aria-pressed={tool === id}
          aria-controls={`workspace-panel-${id === 'edit' || id === 'preview' ? id : 'paper'}`}
          onClick={() => onSelect(id)}
        >
          {!mobile && <Icon size={17} aria-hidden="true" />}
          {t(label)}
        </Button>
      ))}
    </nav>
  );
}

export function WorkspaceToolbar({
  openAppearance,
  children,
  status,
}: {
  openAppearance: () => void;
  children: ReactNode;
  status?: ReactNode;
}) {
  const { t } = useI18n();
  return (
    <div className="workspace-actions">
      <Button
        className="mobile-settings-button"
        variant="ghost"
        data-testid="mobile-settings-btn"
        aria-label={t('appearance')}
        onClick={openAppearance}
      >
        <SlidersHorizontal size={16} aria-hidden="true" />
        <span>{t('appearance')}</span>
      </Button>
      {status && <div className="canvas-status">{status}</div>}
      {children}
    </div>
  );
}

export function PreviewActions({
  onGenerate,
  live,
  onLiveChanged,
  compact,
}: {
  onGenerate: () => void;
  live: boolean | undefined;
  onLiveChanged: (live: boolean) => void;
  compact: boolean;
}) {
  const { t } = useI18n();
  return (
    <>
      {live !== undefined && (
        <label className="check-row live-preview-toggle" data-testid="live-preview-toggle">
          <input
            type="checkbox"
            checked={live}
            onChange={(event) => onLiveChanged(event.target.checked)}
          />
          {t('livePreview')}
        </label>
      )}
      <GenerateButton testId="preview-btn" compact={compact} onGenerate={onGenerate} />
    </>
  );
}
