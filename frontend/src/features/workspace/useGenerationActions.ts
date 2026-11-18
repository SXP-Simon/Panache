import { useCallback, useEffect, useRef } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useGeneration } from '@/features/generation/useGeneration';
import { GenerationStoppedError } from '@/features/generation/cancellation';
import { readGenerationState } from '@/features/generation/state';
import { useDocumentStore } from '@/features/document/store';
import { useSettingsStore } from '@/features/settings/store';
import { usePreviewStore } from '@/features/preview/store';
import type { PreviewSource } from '@/features/preview/store';
import { useFineEditStore } from '@/features/preview/fineEditStore';
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
  const complete = useCallback(
    async (
      pending: Promise<GenerationResult>,
      token: number,
      options?: { current: () => boolean; source: PreviewSource; live: boolean },
    ) => {
      const current = options?.current;
      try {
        const result = await pending;
        if (!mounted.current || token !== sequence.current) return;
        if (current && !current()) {
          if (result.type === 'images') {
            for (const url of result.images) if (url.startsWith('blob:')) URL.revokeObjectURL(url);
          }
          await removeRecord('studio.generation');
          return;
        }
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
            result.type === 'images' ? result.inkLayers : undefined,
            Boolean(options?.live) || Boolean(result.type === 'images' && result.fineEdit),
            result.type === 'images' ? result.latinInkLayers : undefined,
            result.type === 'images' && result.fineEdit
              ? { ...result.fineEdit, text: options?.source.draft.text ?? null }
              : undefined,
            options?.source,
          );
          if (!options?.live) useNotificationStore.getState().inform('previewLoaded');
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
          if (cause.code === 'cancelled')
            useNotificationStore.getState().inform('generationStopped');
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
    },
    [],
  );
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
    async (mode: GenerationMode, live = false) => {
      const current = readGenerationState(client);
      if (current.busy || current.retrySeconds > 0) return;
      const settings = useSettingsStore.getState();
      const document = useDocumentStore.getState();
      const fine = useFineEditStore.getState();
      const snapshot = { ...settings, ...document, fineEdit: fine.enabled, fineEdits: fine.saved };
      const invalid = validateGeneration(snapshot);
      if (invalid) {
        if (!live) useNotificationStore.getState().fail(invalid);
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
        mode === 'preview'
          ? {
              live,
              source: { draft: document, settings, fine: fine.enabled },
              current: () =>
                (!live && !fine.enabled) ||
                (settings === useSettingsStore.getState() &&
                  document === useDocumentStore.getState() &&
                  fine.enabled === useFineEditStore.getState().enabled),
            }
          : undefined,
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
