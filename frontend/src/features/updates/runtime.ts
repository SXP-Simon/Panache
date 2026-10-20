import { queryClient } from '@/api/queryClient';
import { useGenerationState, readGenerationState } from '@/features/generation/state';
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
let manualCheckRequested = false;
export function showUpdatePrompt(manual = true): void {
  const update = snapshot();
  const key = update.version ? `release:${update.version}` : update.deploymentId;
  if (
    !key ||
    !['available', 'downloading', 'ready', 'launched', 'cancelled'].includes(update.status)
  )
    return;
  useUpdatesStore.getState().requestPrompt(update, key, manual);
}
export function checkUpdates(source: 'manual' | 'automatic' = 'manual'): Promise<void> {
  if (
    source === 'automatic' &&
    (useUpdatesStore.getState().prompt ||
      ['downloading', 'ready', 'launched'].includes(snapshot().status))
  )
    return Promise.resolve();
  if (source === 'manual') manualCheckRequested = true;
  if (checking) return checking;
  emit({ ...snapshot(), status: 'checking', error: undefined });
  checking = (async () => {
    try {
      const bridge = window.handwritingDesktop?.updates;
      if (bridge) emit(await bridge.check());
      else
        emit({
          status: (await checkDeploymentUpdate()) ? 'available' : 'current',
          deploymentId: getPwaState().updateId,
        });
      if (snapshot().status === 'available') showUpdatePrompt(manualCheckRequested);
    } catch (error) {
      emit({
        ...snapshot(),
        status: 'error',
        error: error instanceof Error ? error.message : 'network',
      });
    } finally {
      checking = null;
      manualCheckRequested = false;
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
export function useInitializeUpdates(otherModalOpen = false): void {
  const auto = usePreferencesStore((value) => value.autoCheckUpdates);
  const busy = useGenerationState((value) => value.busy);
  const pending = useUpdatesStore((value) => value.pendingPrompt);
  useEffect(() => {
    if (!pending) return;
    const show = () => {
      if (
        !busy &&
        pending &&
        (pending.manual || (!otherModalOpen && !document.querySelector('dialog[open]'))) &&
        document.visibilityState === 'visible'
      )
        useUpdatesStore.getState().showPending();
    };
    show();
    document.addEventListener('visibilitychange', show);
    const dialogs = new MutationObserver(show);
    dialogs.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['open'],
    });
    return () => {
      document.removeEventListener('visibilitychange', show);
      dialogs.disconnect();
    };
  }, [busy, pending, otherModalOpen]);
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
      if (getPwaState().updateAvailable) {
        emit({ status: 'available', deploymentId: getPwaState().updateId });
        if (usePreferencesStore.getState().autoCheckUpdates) showUpdatePrompt(false);
      }
    });
  }, []);
  useEffect(() => {
    if (!auto) return;
    const timer = setTimeout(() => {
      void checkUpdates('automatic');
    }, 3000);
    const interval = setInterval(
      () => {
        if (document.visibilityState === 'visible' && navigator.onLine)
          void checkUpdates('automatic');
      },
      6 * 60 * 60 * 1000,
    );
    return () => {
      clearTimeout(timer);
      clearInterval(interval);
    };
  }, [auto]);
}
