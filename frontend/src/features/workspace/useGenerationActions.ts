import { useCallback, useEffect, useRef } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useGeneration } from '@/features/generation/useGeneration';
import { GenerationStoppedError } from '@/features/generation/cancellation';
import { readGenerationState } from '@/features/generation/state';
import { useDocumentStore } from '@/features/document/store';
import { useSettingsStore } from '@/features/settings/store';
import { usePreviewStore } from '@/features/preview/store';
import { replacePreview } from '@/features/preview/resources';
import { useNotificationStore } from '@/features/notifications/store';
import { ApiError } from '@/api/client';
import { downloadResult } from '@/api/download';
import type { GenerationMode, GenerationResult } from '@/api/types';
import { removeRecord, writeRecord } from '@/persistence';
import { takeRestoredGeneration } from './persistenceRuntime';
import { validateGeneration } from './validation';
import { reportFailure } from './reportFailure';

export function useGenerationActions() {
  const { generate: create, resume, cancel } = useGeneration();
  const client = useQueryClient();
  const downloads = useRef(new Set<() => void>());
  const mounted = useRef(true);
  const sequence = useRef(0);
  const complete = useCallback(async (pending: Promise<GenerationResult>, token: number) => {
    try {
      const result = await pending;
      if (!mounted.current || token !== sequence.current) return;
      if (result.type === 'download') {
        usePreviewStore
          .getState()
          .setDownload({ savedPath: '', pdfBytes: result.mode === 'pdf' ? result.blob.size : 0 });
        downloads.current.add(downloadResult(result.blob, result.mode));
        useNotificationStore
          .getState()
          .inform(window.handwritingDesktop ? 'downloadDesktop' : 'downloadBrowser');
      } else {
        replacePreview(
          result.type === 'images' ? result.images : [URL.createObjectURL(result.blob)],
        );
        useNotificationStore.getState().inform('previewLoaded');
      }
      await removeRecord('studio.generation');
    } catch (cause) {
      if (!mounted.current || token !== sequence.current) return;
      if (cause instanceof GenerationStoppedError) {
        try {
          await removeRecord('studio.generation');
        } catch {
          useNotificationStore.getState().fail('storageUnavailable');
        }
        if (cause.code === 'cancelled') useNotificationStore.getState().inform('generationStopped');
        return;
      }
      if (cause instanceof ApiError && cause.code === 'cancelled') return;
      // Transport/task failures already live in the shared query cache.
      if (!(cause instanceof ApiError)) reportFailure(cause);
      if (
        cause instanceof ApiError &&
        (cause.code === 'taskFailed' ||
          cause.code === 'queueFull' ||
          (cause.status !== undefined &&
            cause.status >= 400 &&
            cause.status < 500 &&
            cause.status !== 408))
      ) {
        try {
          await removeRecord('studio.generation');
        } catch {
          useNotificationStore.getState().fail('storageUnavailable');
        }
      }
    }
  }, []);
  useEffect(() => {
    mounted.current = true;
    const saved = takeRestoredGeneration();
    if (saved) {
      useNotificationStore.getState().clear();
      void complete(
        resume(saved.taskId, saved.mode, saved.cancelling, async (taskId) => {
          try {
            await writeRecord(
              'studio.generation',
              JSON.stringify({ version: 1, taskId, mode: saved.mode, cancelling: true }),
            );
          } catch {
            useNotificationStore.getState().fail('storageUnavailable');
          }
        }),
        ++sequence.current,
      );
    }
    const activeDownloads = downloads.current;
    const unsubscribe = window.handwritingDesktop?.onDownloadFinished((payload) => {
      if (mounted.current)
        usePreviewStore
          .getState()
          .setDownload({ savedPath: payload.state === 'completed' ? payload.file : '' });
    });
    return () => {
      mounted.current = false;
      unsubscribe?.();
      for (const clean of activeDownloads) clean();
      activeDownloads.clear();
    };
  }, [complete, resume]);
  const generate = useCallback(
    async (mode: GenerationMode) => {
      const current = readGenerationState(client);
      if (current.busy || current.retrySeconds > 0) return;
      const snapshot = { ...useSettingsStore.getState(), ...useDocumentStore.getState() };
      const invalid = validateGeneration(snapshot);
      if (invalid) {
        useNotificationStore.getState().fail(invalid);
        return;
      }
      useNotificationStore.getState().clear();
      await complete(
        create(snapshot, mode, {
          onStopping: async (taskId) => {
            try {
              await writeRecord(
                'studio.generation',
                JSON.stringify({ version: 1, taskId, mode, cancelling: true }),
              );
            } catch {
              useNotificationStore.getState().fail('storageUnavailable');
            }
          },
          onCreated: async (taskId) => {
            try {
              await writeRecord('studio.generation', JSON.stringify({ version: 1, taskId, mode }));
            } catch {
              useNotificationStore.getState().fail('storageUnavailable');
            }
          },
        }),
        ++sequence.current,
      );
    },
    [client, complete, create],
  );
  const cancelGeneration = useCallback(async () => {
    useNotificationStore.getState().clear();
    try {
      await cancel();
    } catch {
      /* Cancellation failure stays visible with the retry action in shared state. */
    }
  }, [cancel]);
  return { generate, cancelGeneration };
}
