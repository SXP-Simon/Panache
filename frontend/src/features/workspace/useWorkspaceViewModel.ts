import { useEffect, useRef, useState } from 'react';
import { useFontsQuery } from '@/api/catalog';
import { useDocumentStore } from '@/features/document/store';
import { useGenerationState } from '@/features/generation/state';
import { usePreferencesStore } from '@/features/preferences/store';
import { clearPreview } from '@/features/preview/resources';
import { usePreviewStore } from '@/features/preview/store';
import { useSettingsStore } from '@/features/settings/store';
import { useWorkspaceActions } from './WorkspaceProvider';

export type WorkspacePane = 'edit' | 'paper' | 'preview';
export type SettingsSection = 'layout' | 'paper' | 'ink' | 'presets';
export type CanvasTool = 'edit' | SettingsSection;

export function useWorkspaceViewModel() {
  const { generate } = useWorkspaceActions();
  const [pane, setPane] = useState<WorkspacePane>('edit');
  const [settingsSection, setSettingsSection] = useState<SettingsSection>('layout');
  const [canvas] = useState(
    () => new URLSearchParams(window.location.search).get('studio') !== 'classic',
  );
  const live = usePreferencesStore((state) => state.livePreview);
  const navigation = useRef(0);

  function setLive(livePreview: boolean) {
    usePreferencesStore.getState().patch({ livePreview });
  }

  function selectPane(next: WorkspacePane) {
    navigation.current += 1;
    setPane(next);
    window.scrollTo(0, 0);
  }

  function selectTool(tool: CanvasTool | 'preview') {
    if (tool === 'edit' || tool === 'preview') {
      selectPane(tool);
    } else {
      setSettingsSection(tool);
      selectPane('paper');
    }
  }

  async function generatePreview() {
    const narrow = window.matchMedia('(max-width: 720px)');
    const revision = navigation.current;
    const draft = useDocumentStore.getState();
    const previous = usePreviewStore.getState().images;
    await generate('preview');
    const images = usePreviewStore.getState().images;
    const editing = document.activeElement?.closest(
      'input, textarea, select, [contenteditable], dialog',
    );
    if (
      narrow.matches &&
      navigation.current === revision &&
      useDocumentStore.getState() === draft &&
      images !== previous &&
      images.length &&
      !editing
    ) {
      selectPane('preview');
    }
  }

  return {
    canvas,
    live,
    setLive,
    pane,
    selectPane,
    settingsSection,
    selectTool,
    generatePreview,
  };
}

export function useLivePreview(active: boolean) {
  const { generate } = useWorkspaceActions();
  const blocked = useGenerationState((state) => state.busy || state.retrySeconds > 0);
  const fonts = useFontsQuery();
  const draft = useDocumentStore();
  const settings = useSettingsStore();
  const hasPreview = usePreviewStore((state) => state.images.length > 0);
  const submitted = useRef<{ draft: typeof draft; settings: typeof settings } | null>(null);

  useEffect(() => {
    if (!active) return;
    if (!draft.text.trim()) {
      submitted.current = null;
      if (hasPreview) clearPreview();
      return;
    }
    if (
      blocked ||
      !fonts.data?.length ||
      (submitted.current?.draft === draft && submitted.current.settings === settings)
    )
      return;

    const timer = window.setTimeout(
      () => {
        submitted.current = { draft, settings };
        void generate('preview', true);
      },
      settings.fullPreview ? 750 : 300,
    );
    return () => window.clearTimeout(timer);
  }, [active, blocked, draft, fonts.data, generate, hasPreview, settings]);
}
