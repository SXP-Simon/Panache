import { queryClient } from '@/api/queryClient';
import { readGenerationState } from '@/features/generation/state';
import { useEffect } from 'react';
import { useUpdatesStore } from './store';
import { usePreferencesStore } from '@/features/preferences/store';
import { flushWorkspaceNow } from '@/features/workspace/persistenceRuntime';
import { useSaveStatus } from '@/features/workspace/saveStatus';
import { activateDeploymentUpdate, checkDeploymentUpdate, getPwaState, subscribePwa } from '@/pwa';
import type { UpdateState } from './contracts';
const snapshot = () => useUpdatesStore.getState().update;
const emit = (next: UpdateState) => useUpdatesStore.getState().replace(next);
let checking: Promise<void> | null = null;
export function checkUpdates(): Promise<void> {
  if (checking) return checking;
  emit({ ...snapshot(), status: 'checking', error: undefined });
  checking = (async () => {
    try {
      const bridge = window.handwritingDesktop?.updates;
      if (bridge) emit(await bridge.check());
      else emit({ status: (await checkDeploymentUpdate()) ? 'available' : 'current' });
    } catch (error) {
      emit({
        ...snapshot(),
        status: 'error',
        error: error instanceof Error ? error.message : 'network',
      });
    } finally {
      checking = null;
    }
  })();
  return checking;
}
export async function updateAction(action: 'download' | 'cancel' | 'open'): Promise<void> {
  try {
    if (action === 'open' && readGenerationState(queryClient).busy)
      throw new Error('generationBusy');
    const bridge = window.handwritingDesktop?.updates;
    if (bridge) emit(await bridge[action]());
    else if (action === 'open') {
      await flushWorkspaceNow();
      if (useSaveStatus.getState().status !== 'saved') throw new Error('saveFailed');
      await activateDeploymentUpdate();
    }
  } catch (error) {
    emit({
      ...snapshot(),
      status: 'error',
      error: error instanceof Error ? error.message : 'network',
    });
  }
}
export function useUpdateState(): UpdateState {
  return useUpdatesStore((value) => value.update);
}
export function useInitializeUpdates(): void {
  const auto = usePreferencesStore((value) => value.autoCheckUpdates);
  useEffect(() => {
    const bridge = window.handwritingDesktop?.updates;
    if (bridge) {
      void bridge
        .state()
        .then(emit)
        .catch(() => {});
      return bridge.subscribe(emit);
    }
    return subscribePwa(() => {
      if (getPwaState().updateAvailable) emit({ status: 'available' });
    });
  }, []);
  useEffect(() => {
    if (!auto) return;
    const timer = setTimeout(() => {
      void checkUpdates();
    }, 3000);
    const interval = setInterval(
      () => {
        if (document.visibilityState === 'visible' && navigator.onLine) void checkUpdates();
      },
      6 * 60 * 60 * 1000,
    );
    return () => {
      clearTimeout(timer);
      clearInterval(interval);
    };
  }, [auto]);
}
