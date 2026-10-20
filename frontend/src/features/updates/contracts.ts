export type UpdateStatus =
  | 'development'
  | 'launched'
  | 'idle'
  | 'checking'
  | 'current'
  | 'available'
  | 'unsupported'
  | 'pending'
  | 'downloading'
  | 'preparing'
  | 'installing'
  | 'cancelled'
  | 'ready'
  | 'error';
export interface UpdateState {
  status: UpdateStatus;
  current?: string;
  version?: string;
  deploymentId?: string;
  releaseUrl?: string;
  notes?: string;
  portable?: boolean;
  bytes?: number;
  total?: number;
  error?: string | undefined;
  manualAvailable?: boolean;
  recovery?: string | null;
}
