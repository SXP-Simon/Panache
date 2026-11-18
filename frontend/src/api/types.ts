import type { defaultNumbers } from '../models.ts';
import type { DigitFont, LatinFont, PaperPattern } from '../models.ts';
import type { ImageStore } from '../utils/inlineImageManager.ts';

export type GenerationMode = 'preview' | 'zip' | 'pdf';
export type DownloadMode = Exclude<GenerationMode, 'preview'>;
export interface GenerationSnapshot {
  text: string;
  imageStore: ImageStore;
  numbers: typeof defaultNumbers;
  selectedFont: string;
  selectedLatinFont?: LatinFont | '';
  digitFont?: DigitFont;
  fontFile: File | null;
  background: File | null;
  backgroundRuled?: boolean;
  layoutStyle?: 'standard' | 'homework';
  firstLineIndent?: boolean;
  monospaced?: boolean;
  underlined: boolean;
  paperPattern?: PaperPattern | '';
  englishSpacing: boolean;
  fullPreview: boolean;
  ink: string;
  separateLatinInk?: boolean;
  latinInk?: string;
}
export type GenerationResult =
  | { type: 'images'; images: string[]; inkLayers?: string[]; latinInkLayers?: (string | null)[] }
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
