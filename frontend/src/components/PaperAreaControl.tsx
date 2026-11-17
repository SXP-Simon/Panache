import { useState } from 'react';
import { useSettingsStore } from '@/features/settings/store';
import { useI18n } from '@/i18n';
import Button from '../shared/ui/Button';
import { ScanLine } from '../shared/icons';
import PaperAreaDialog from './PaperAreaDialog';

export default function PaperAreaControl({ inPreview = false }: { inPreview?: boolean }) {
  const source = useSettingsStore((state) => state.backgroundUrl);
  const [open, setOpen] = useState(false);
  const { t } = useI18n();
  if (!source) return null;
  return (
    <>
      <Button
        size="small"
        variant="tonal"
        data-testid={inPreview ? 'preview-adjust-paper-area' : 'adjust-paper-area'}
        onClick={() => setOpen(true)}
      >
        <ScanLine size={16} />
        {t('paperAreaAction')}
      </Button>
      {open && <PaperAreaDialog key={source} source={source} close={() => setOpen(false)} />}
    </>
  );
}
