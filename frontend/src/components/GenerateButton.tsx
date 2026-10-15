import { useFontsQuery } from '@/api/catalog';
import { useGenerationState } from '@/features/generation/state';
import { useWorkspaceActions } from '@/features/workspace/WorkspaceProvider';
import { useI18n } from '@/i18n';
import { Eye, LoaderCircle } from '@/shared/icons';
import Button from '@/shared/ui/Button';

export function useGenerationAvailability() {
  const busy = useGenerationState((state) => state.busy);
  const retrySeconds = useGenerationState((state) => state.retrySeconds);
  const fonts = useFontsQuery();
  return { busy, disabled: busy || retrySeconds > 0 || !fonts.data?.length };
}
export default function GenerateButton({
  testId,
  compact = false,
}: {
  testId?: string;
  compact?: boolean;
}) {
  const { t } = useI18n();
  const { generate } = useWorkspaceActions();
  const { busy, disabled } = useGenerationAvailability();
  return (
    <Button
      variant="primary"
      data-testid={testId}
      disabled={disabled}
      onClick={() => void generate('preview')}
    >
      {busy ? (
        <LoaderCircle className="spin" size={compact ? 16 : 17} />
      ) : (
        <Eye size={compact ? 16 : 17} />
      )}
      {t('previewAction')}
    </Button>
  );
}
