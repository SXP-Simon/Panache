import { useDocumentStore } from '@/features/document/store';
import type { DocumentData } from '@/features/document/store';
import { useSettingsStore } from '@/features/settings/store';
import type { SettingsData } from '@/features/settings/store';
import { changeBackground } from '@/features/preview/resources';
import { captureAssets, releaseSnapshot } from '@/persistence/assetSnapshots';
import type { AssetSnapshot } from '@/persistence/assetSnapshots';
import { flushWorkspaceNow } from './persistenceRuntime';
import { useSaveStatus } from './saveStatus';

interface ResourceChange {
  document?: DocumentData;
  settings?: Partial<SettingsData>;
}
/** Publish resources after their binary commit so an immediate reload can save metadata synchronously. */
export async function updateResources(
  transform: (document: DocumentData, settings: SettingsData) => ResourceChange,
  current: () => boolean = () => true,
): Promise<boolean> {
  while (current()) {
    const document = useDocumentStore.getState();
    const settings = useSettingsStore.getState();
    const change = transform(document, settings);
    let snapshot: AssetSnapshot | null = null;
    try {
      try {
        snapshot = await captureAssets(change.document ?? document, {
          ...settings,
          ...change.settings,
        });
      } catch {
        // Keep uploads usable in memory; autosave exposes the failure and preserves the last complete record.
      }
      if (!current()) return false;
      if (document !== useDocumentStore.getState() || settings !== useSettingsStore.getState())
        continue;
      if (change.document) document.replace(change.document);
      if (change.settings) {
        if ('background' in change.settings) {
          changeBackground(change.settings.background ?? null);
          change.settings.backgroundUrl = useSettingsStore.getState().backgroundUrl;
        }
        settings.patch(change.settings);
      }
      await flushWorkspaceNow();
      return useSaveStatus.getState().status === 'saved';
    } finally {
      if (snapshot) releaseSnapshot(snapshot);
    }
  }
  return false;
}
