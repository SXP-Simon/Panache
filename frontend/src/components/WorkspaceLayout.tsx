import { useSyncExternalStore } from 'react';
import { useLivePreview, useWorkspaceViewModel } from '@/features/workspace/useWorkspaceViewModel';
import EditorPanel from './EditorPanel';
import PreviewPanel from './PreviewPanel';
import SettingsPanel from './SettingsPanel';
import {
  PreviewActions,
  WorkspaceNavigation,
  WorkspaceToolbar,
  WorkspaceToolNavigation,
} from './WorkspaceControls';
import WorkspaceStatus from './WorkspaceStatus';

const mobileWorkspace = window.matchMedia('(max-width: 720px)');

function subscribeToMobileWorkspace(onChange: () => void) {
  mobileWorkspace.addEventListener('change', onChange);
  return () => mobileWorkspace.removeEventListener('change', onChange);
}

function isMobileWorkspace() {
  return mobileWorkspace.matches;
}

function LivePreview({ active }: { active: boolean }) {
  useLivePreview(active);
  return null;
}

export default function WorkspaceLayout({ openAppearance }: { openAppearance: () => void }) {
  const { pane, canvas, live, setLive, selectPane, settingsSection, selectTool, generatePreview } =
    useWorkspaceViewModel();
  const mobile = useSyncExternalStore(subscribeToMobileWorkspace, isMobileWorkspace);
  const controlsInPreview = canvas && !mobile;
  const settingsPanel = <SettingsPanel section={canvas ? settingsSection : undefined} />;
  const previewActions = (
    <PreviewActions
      onGenerate={() => void generatePreview()}
      live={canvas ? live : undefined}
      onLiveChanged={setLive}
      compact={controlsInPreview}
    />
  );

  return (
    <>
      {canvas && <LivePreview active={live} />}
      {!controlsInPreview && (
        <WorkspaceToolbar
          openAppearance={openAppearance}
          status={canvas ? <WorkspaceStatus /> : undefined}
        >
          {previewActions}
        </WorkspaceToolbar>
      )}
      {canvas ? (
        <WorkspaceToolNavigation
          mobile
          tool={pane === 'paper' ? settingsSection : pane}
          onSelect={selectTool}
        />
      ) : (
        <WorkspaceNavigation pane={pane} onSelect={selectPane} />
      )}
      {!canvas && <WorkspaceStatus />}
      <div
        className="workspace-grid"
        data-studio={canvas ? 'canvas' : undefined}
        data-pane={pane}
        data-testid="workspace"
      >
        {canvas && (
          <WorkspaceToolNavigation
            tool={pane === 'paper' ? settingsSection : 'edit'}
            onSelect={selectTool}
          />
        )}
        <EditorPanel />
        {canvas && settingsPanel}
        <PreviewPanel
          keepVisible={canvas}
          headingActions={controlsInPreview ? previewActions : undefined}
        />
        {!canvas && settingsPanel}
      </div>
    </>
  );
}
