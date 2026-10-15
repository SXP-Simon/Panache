import { useCallback, useEffect, useRef } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { catalogKeys } from '@/api/catalog';
import { useSettingsStore } from '@/features/settings/store';
import { useNotificationStore } from '@/features/notifications/store';
import { changeBackground } from '@/features/preview/resources';
import { savePreset, loadPreset } from '@/features/settings/presetRepository';
import { useDocumentStore } from '@/features/document/store';
import { updateResources } from './resourceUpdates';

export function useSettingsActions() {
  const client = useQueryClient();
  const sequence = useRef(0);
  const pendingSave = useRef<Promise<void>>(Promise.resolve());
  const uploadSequence = useRef({ font: 0, background: 0 });
  const pendingUploads = useRef<{
    font: Promise<void> | null;
    background: Promise<boolean> | null;
  }>({ font: null, background: null });
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const saveSettings = useCallback(async () => {
    const request = ++sequence.current;
    const save = Promise.all([pendingUploads.current.font, pendingUploads.current.background]).then(
      () => savePreset(useDocumentStore.getState(), useSettingsStore.getState()),
    );
    pendingSave.current = save;
    try {
      await save;
      if (mounted.current && request === sequence.current)
        useNotificationStore.getState().inform('saved');
    } catch {
      if (mounted.current && request === sequence.current)
        useNotificationStore.getState().fail('storageUnavailable');
    }
  }, []);
  const loadSettings = useCallback(async () => {
    const request = ++sequence.current;
    uploadSequence.current.font += 1;
    uploadSequence.current.background += 1;
    try {
      const document = useDocumentStore.getState();
      const settings = useSettingsStore.getState();
      await pendingSave.current.catch(() => {});
      const restored = await loadPreset(
        settings,
        client.getQueryData<string[]>(catalogKeys.fonts) ?? [],
      );
      if (
        !mounted.current ||
        request !== sequence.current ||
        document !== useDocumentStore.getState() ||
        settings !== useSettingsStore.getState()
      )
        return;
      if (!restored) {
        useNotificationStore.getState().inform('noPreset');
        return;
      }
      if (restored.replaceBackground) {
        changeBackground(restored.settings.background);
        restored.settings.backgroundUrl = useSettingsStore.getState().backgroundUrl;
      }
      if (restored.document) document.replace(restored.document);
      settings.patch(restored.settings);
      useNotificationStore.getState().inform('loaded');
    } catch {
      if (mounted.current && request === sequence.current)
        useNotificationStore.getState().fail('invalidPreset');
    }
  }, [client]);
  const resetSettings = useCallback(() => {
    sequence.current += 1;
    uploadSequence.current.font += 1;
    uploadSequence.current.background += 1;
    changeBackground(null);
    useSettingsStore.getState().reset(client.getQueryData<string[]>(catalogKeys.fonts)?.[0] ?? '');
    useNotificationStore.getState().clear();
  }, [client]);
  const applyPreset = useCallback(
    (value: string) => {
      sequence.current += 1;
      uploadSequence.current.font += 1;
      uploadSequence.current.background += 1;
      const applied = useSettingsStore
        .getState()
        .applyPreset(value, client.getQueryData<string[]>(catalogKeys.fonts) ?? []);
      useNotificationStore.getState().inform(applied ? 'presetApplied' : 'presetBackground');
    },
    [client],
  );
  const uploadFont = useCallback((file: File) => {
    const request = ++uploadSequence.current.font;
    const pending = updateResources(
      () => ({ settings: { fontFile: file, selectedFont: file.name } }),
      () => mounted.current && request === uploadSequence.current.font,
    ).then(() => {});
    pendingUploads.current.font = pending;
    return pending;
  }, []);
  const uploadBackground = useCallback((file: File) => {
    const request = ++uploadSequence.current.background;
    const pending = updateResources(
      () => ({ settings: { background: file } }),
      () => mounted.current && request === uploadSequence.current.background,
    ).then((saved) => {
      if (saved && mounted.current && request === uploadSequence.current.background)
        useNotificationStore.getState().inform('backgroundLoaded');
      return mounted.current && request === uploadSequence.current.background;
    });
    pendingUploads.current.background = pending;
    return pending;
  }, []);
  const removeBackground = useCallback(() => {
    uploadSequence.current.background += 1;
    changeBackground(null);
  }, []);
  return {
    saveSettings,
    loadSettings,
    resetSettings,
    applyPreset,
    uploadFont,
    uploadBackground,
    removeBackground,
  };
}
