import { ApiError } from '@/api/client';
import { useNotificationStore } from '@/features/notifications/store';

export function reportFailure(cause: unknown): void {
  const notifications = useNotificationStore.getState();
  if (cause instanceof ApiError) {
    if (cause.code === 'cancelled' || cause.code === 'queueFull') return;
    if (cause.serverMessage) notifications.failText(cause.serverMessage);
    else notifications.fail(cause.code);
  } else if (cause instanceof Error) notifications.failText(cause.message);
  else notifications.fail('networkError');
}
