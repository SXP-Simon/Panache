import { queryClient } from '@/api/queryClient';
import { useGenerationState, readGenerationState } from '@/features/generation/state';
import { useEffect } from 'react';
import { useUpdatesStore } from './store';
import { usePreferencesStore } from '@/features/preferences/store';
import { flushWorkspaceNow } from '@/features/workspace/persistenceRuntime';
import { useSaveStatus } from '@/features/workspace/saveStatus';
import { activateDeploymentUpdate, checkDeploymentUpdate, getPwaState, subscribePwa } from '@/pwa';
import type { UpdateState } from './contracts';
import { useNotificationStore } from '@/features/notifications/store';
const snapshot = () => useUpdatesStore.getState().update;
const emit = (next: UpdateState) => useUpdatesStore.getState().replace(next);
let checking: Promise<void> | null = null;
let manualCheckRequested = false;
let installIntent = false;
let installing: Promise<void> | null = null;
export function deferUpdate(): void {
  installIntent = false;
  if (snapshot().status === 'preparing') void updateAction('cancel');
}
async function installWhenIdle(): Promise<void> {
  if (
    !installIntent ||
    installing ||
    snapshot().status !== 'ready' ||
    readGenerationState(queryClient).busy
  )
    return;
  installing = (async () => {
    const bridge = window.handwritingDesktop?.updates;
    if (bridge && installIntent) emit(await bridge.open());
  })()
    .catch((error: unknown) => {
      installIntent = false;
      emit({
        ...snapshot(),
        status: 'error',
        error: error instanceof Error ? error.message : 'helperFailed',
      });
    })
    .finally(() => {
      installing = null;
    });
  await installing;
}
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
      ['downloading', 'ready', 'launched', 'preparing', 'installing'].includes(snapshot().status))
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
export async function updateAction(
  action: 'download' | 'cancel' | 'open' | 'manual',
): Promise<void> {
  try {
    if (action === 'cancel' || action === 'manual') installIntent = false;
    if (['open', 'manual'].includes(action) && readGenerationState(queryClient).busy)
      throw new Error('generationBusy');
    const bridge = window.handwritingDesktop?.updates;
    if (bridge) {
      if (action === 'download' || action === 'open') installIntent = true;
      if (action === 'open') await installWhenIdle();
      else {
        emit(await bridge[action]());
        if (action === 'download') await installWhenIdle();
      }
    } else if (action === 'open') {
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
    if (!busy) void installWhenIdle();
  }, [busy]);
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
        .then((state) => {
          emit(state);
          if (state.recovery) useNotificationStore.getState().inform('updateRecovered');
        })
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
