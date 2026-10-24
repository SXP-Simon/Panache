import { useCallback, useEffect, useRef } from 'react';
import { useMutation } from '@tanstack/react-query';
import { detectBackground, importDocument } from '@/api/documents';
import { useDocumentStore } from '@/features/document/store';
import { useSettingsStore } from '@/features/settings/store';
import { useNotificationStore } from '@/features/notifications/store';
import { reportFailure } from './reportFailure';
import { updateResources } from './resourceUpdates';
import { collapseInlineImages } from '@/utils/inlineImageManager';
import { correctedPaper, detectedLayout } from './backgroundDetection';

export function useDocumentActions() {
  const imports = useRef<AbortController | null>(null);
  const detections = useRef<AbortController | null>(null);
  useEffect(
    () => () => {
      imports.current?.abort();
      detections.current?.abort();
    },
    [],
  );
  const { mutateAsync: readDocument, reset: resetImport } = useMutation({
    mutationKey: ['documents', 'import'],
    retry: false,
    networkMode: 'always',
    gcTime: 0,
    mutationFn: ({ file, controller }: { file: File; controller: AbortController }) =>
      importDocument(file, controller.signal),
  });
  const { mutateAsync: detect, reset: resetDetection } = useMutation({
    mutationKey: ['documents', 'detect-background'],
    retry: false,
    networkMode: 'always',
    gcTime: 0,
    mutationFn: ({ file, controller }: { file: File; controller: AbortController }) =>
      detectBackground(file, controller.signal),
  });
  const importText = useCallback(
    async (file: File) => {
      imports.current?.abort();
      const controller = new AbortController();
      imports.current = controller;
      const document = useDocumentStore.getState();
      try {
        const result = await readDocument({ file, controller });
        if (controller.signal.aborted) return;
        if (document !== useDocumentStore.getState()) {
          useNotificationStore.getState().inform('importDiscarded');
          return;
        }
        const draft = collapseInlineImages(result.text, document.imageStore);
        const saved = await updateResources(
          () => ({
            document: {
              text: draft.collapsedText,
              imageStore: draft.imageStore,
              textFileName: file.name,
            },
          }),
          () => !controller.signal.aborted && document === useDocumentStore.getState(),
        );
        if (saved) useNotificationStore.getState().inform('uploaded');
      } catch (cause) {
        if (!controller.signal.aborted) reportFailure(cause);
      } finally {
        if (imports.current === controller) {
          imports.current = null;
          resetImport();
        }
      }
    },
    [readDocument, resetImport],
  );
  const detectPaper = useCallback(async () => {
    const initial = useSettingsStore.getState();
    const file = initial.background;
    if (!file) return;
    detections.current?.abort();
    const controller = new AbortController();
    detections.current = controller;
    const current = () => {
      const settings = useSettingsStore.getState();
      return (
        !controller.signal.aborted &&
        settings.background === file &&
        settings.numbers === initial.numbers
      );
    };
    try {
      const margins = await detect({ file, controller });
      if (!current()) return;
      const layout = detectedLayout(margins);
      const fontAdjusted = initial.numbers.font_size >= layout.line_spacing;
      const fontSize = fontAdjusted
        ? Math.max(1, Math.floor(layout.line_spacing * 0.72))
        : initial.numbers.font_size;
      const background = await correctedPaper(file, margins);
      if (!current()) return;
      let publishedNumbers: typeof initial.numbers | undefined;
      await updateResources((_document, settings) => {
        publishedNumbers = { ...settings.numbers, ...layout, font_size: fontSize };
        return {
          settings: {
            backgroundRuled: true,
            ...(background === file ? {} : { background }),
            numbers: publishedNumbers,
          },
        };
      }, current);
      const applied = useSettingsStore.getState();
      if (
        !controller.signal.aborted &&
        applied.background === background &&
        applied.numbers === publishedNumbers
      )
        useNotificationStore
          .getState()
          .inform(fontAdjusted ? 'backgroundAlignedFont' : 'backgroundAligned');
    } catch (cause) {
      if (current()) reportFailure(cause);
    } finally {
      if (detections.current === controller) {
        detections.current = null;
        resetDetection();
      }
    }
  }, [detect, resetDetection]);
  return { importText, detectBackground: detectPaper };
}
