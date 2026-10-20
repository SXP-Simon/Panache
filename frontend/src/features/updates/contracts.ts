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
  | 'cancelled'
  | 'ready'
  | 'error';
export interface UpdateState {
  status: UpdateStatus;
  current?: string;
  version?: string;
  releaseUrl?: string;
  notes?: string;
  portable?: boolean;
  bytes?: number;
  total?: number;
  error?: string | undefined;
}
