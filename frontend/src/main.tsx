import { createRoot } from 'react-dom/client';
import App from './App';
import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from './api/queryClient';
import { WorkspaceProvider } from './features/workspace/WorkspaceProvider';
import {
  hydrateWorkspace,
  startWorkspacePersistence,
  flushWorkspaceNow,
} from './features/workspace/persistenceRuntime';
import { useSaveStatus } from './features/workspace/saveStatus';
import { useNotificationStore } from './features/notifications/store';
import { initializePwa } from './pwa';
import { useEffect } from 'react';
import { readGenerationState } from './features/generation/state';
import './style.css';
const root = document.getElementById('app');
if (!root) throw new Error('The application root is missing');
const application = createRoot(root);
async function start() {
  let restored = false;
  try {
    restored = await hydrateWorkspace();
  } catch {
    useNotificationStore.getState().fail('restoreFailed');
  }
  const stopPersistence = startWorkspacePersistence();
  const stopCloseListener = window.handwritingDesktop?.onBeforeClose?.(async (reason) => {
    if (reason === 'update' && readGenerationState(queryClient).busy)
      throw new Error('generationBusy');
    await flushWorkspaceNow();
    if (useSaveStatus.getState().status !== 'saved') throw new Error('Workspace was not saved');
  });
  const stopPwa = initializePwa();
  application.render(
    <QueryClientProvider client={queryClient}>
      <WorkspaceProvider>
        <App />
        <StartupHealth restored={restored} />
      </WorkspaceProvider>
    </QueryClientProvider>,
  );
  import.meta.hot?.dispose(() => {
    stopPersistence();
    stopCloseListener?.();
    stopPwa();
    application.unmount();
  });
}
function StartupHealth({ restored }: { restored: boolean }) {
  useEffect(() => {
    if (!restored || !window.handwritingDesktop?.updates.healthy) return;
    let cancelled = false;
    const frame = requestAnimationFrame(() => {
      void (async () => {
        await flushWorkspaceNow();
        if (!cancelled && useSaveStatus.getState().status === 'saved')
          await window.handwritingDesktop?.updates.healthy();
      })().catch(() => {});
    });
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
    };
  }, [restored]);
  return null;
}
void start();
