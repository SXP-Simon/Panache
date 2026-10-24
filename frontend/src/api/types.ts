import type { defaultNumbers } from '../models.ts';
import type { ImageStore } from '../utils/inlineImageManager.ts';

export type GenerationMode = 'preview' | 'zip' | 'pdf';
export type DownloadMode = Exclude<GenerationMode, 'preview'>;
export interface GenerationSnapshot {
  text: string;
  imageStore: ImageStore;
  numbers: typeof defaultNumbers;
  selectedFont: string;
  fontFile: File | null;
  background: File | null;
  backgroundRuled?: boolean;
  underlined: boolean;
  englishSpacing: boolean;
  fullPreview: boolean;
  ink: string;
}
export type GenerationResult =
  | { type: 'images'; images: string[] }
  | { type: 'image'; blob: Blob }
  | { type: 'download'; mode: DownloadMode; blob: Blob };
export interface BackgroundMargins {
  marginLeft: number;
  marginRight: number;
  marginTop: number;
  marginBottom: number;
  lineSpacing: number;
  firstBaseline?: number | undefined;
  layoutTopMargin?: number | undefined;
  layoutBottomMargin?: number | undefined;
  imageWidth?: number | undefined;
  imageHeight?: number | undefined;
  deskewAngleDegrees?: number | undefined;
  correctedBackground?: string | undefined;
}
