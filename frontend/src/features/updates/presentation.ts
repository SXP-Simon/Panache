import type { MessageKey } from '@/i18n';
import type { UpdateState, UpdateStatus } from './contracts';
const statuses: Record<UpdateStatus, MessageKey> = {
  development: 'updateDevelopment',
  launched: 'updateLaunched',
  idle: 'updateIdle',
  checking: 'updateChecking',
  current: 'updateCurrent',
  available: 'updateAvailable',
  unsupported: 'updateUnsupported',
  pending: 'updatePending',
  downloading: 'updateDownloading',
  cancelled: 'updateCancelled',
  ready: 'updateReady',
  error: 'updateNetwork',
};
const errors: Record<string, MessageKey> = {
  cleanupFailed: 'updateCleanupFailed',
  generationBusy: 'updateGenerationBusy',
  rateLimited: 'updateRateLimited',
  invalid: 'updateInvalid',
  unsafe: 'updateInvalid',
  integrity: 'updateIntegrity',
  saveFailed: 'updateSaveFailed',
  unsupported: 'updateWebUnsupported',
  pending: 'updatePending',
};
export function updateMessage(state: UpdateState): MessageKey {
  return state.status === 'error'
    ? (errors[state.error ?? ''] ?? 'updateNetwork')
    : statuses[state.status];
}
