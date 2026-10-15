import { createContext, useContext, useEffect, useMemo } from 'react';
import type { ReactNode } from 'react';
import { useFontsQuery } from '@/api/catalog';
import { useDocumentActions } from './useDocumentActions';
import { useSettingsActions } from './useSettingsActions';
import { useGenerationActions } from './useGenerationActions';
import { reconcileFontSelection } from './persistenceRuntime';
import { reportFailure } from './reportFailure';

type WorkspaceActions = ReturnType<typeof useDocumentActions> &
  ReturnType<typeof useSettingsActions> & { generate: ReturnType<typeof useGenerationActions> };
const ActionsContext = createContext<WorkspaceActions | null>(null);

export function WorkspaceProvider({ children }: { children: ReactNode }) {
  const catalog = useFontsQuery();
  const { importText, detectBackground } = useDocumentActions();
  const {
    saveSettings,
    loadSettings,
    resetSettings,
    applyPreset,
    uploadFont,
    uploadBackground,
    removeBackground,
  } = useSettingsActions();
  const generate = useGenerationActions();
  useEffect(() => {
    if (catalog.data) reconcileFontSelection(catalog.data);
  }, [catalog.data]);
  useEffect(() => {
    if (catalog.error) reportFailure(catalog.error);
  }, [catalog.error]);
  const actions = useMemo(
    () => ({
      importText,
      detectBackground,
      saveSettings,
      loadSettings,
      resetSettings,
      applyPreset,
      uploadFont,
      uploadBackground,
      removeBackground,
      generate,
    }),
    [
      importText,
      detectBackground,
      saveSettings,
      loadSettings,
      resetSettings,
      applyPreset,
      uploadFont,
      uploadBackground,
      removeBackground,
      generate,
    ],
  );
  return <ActionsContext.Provider value={actions}>{children}</ActionsContext.Provider>;
}
export function useWorkspaceActions(): WorkspaceActions {
  const actions = useContext(ActionsContext);
  if (!actions) throw new Error('Workspace actions require WorkspaceProvider');
  return actions;
}
