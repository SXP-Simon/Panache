import type { MessageKey } from './i18n';
export const defaultNumbers = {
  font_size: 124,
  line_spacing: 200,
  word_spacing: 1,
  width: 2481,
  height: 3507,
  top_margin: 50,
  bottom_margin: 50,
  left_margin: 50,
  right_margin: 50,
  line_spacing_sigma: 0,
  font_size_sigma: 2,
  word_spacing_sigma: 2,
  perturb_x_sigma: 3,
  perturb_y_sigma: 3,
  perturb_theta_sigma: 0.05,
  strikethrough_probability: 0.005,
  strikethrough_length_sigma: 2,
  strikethrough_angle_sigma: 2,
  strikethrough_width_sigma: 2,
  strikethrough_width: 8,
  ink_depth_sigma: 30,
};
export type NumericKey = keyof typeof defaultNumbers;
export interface NumberField {
  key: NumericKey;
  label: MessageKey;
  testId: string;
  step: number;
  min: number;
}
export const mainFields: readonly NumberField[] = [
  { key: 'font_size', label: 'fontSize', testId: 'font-size-input', step: 1, min: 1 },
  { key: 'line_spacing', label: 'lineSpacing', testId: 'line-spacing-input', step: 1, min: 1 },
  { key: 'word_spacing', label: 'wordSpacing', testId: 'word-spacing-input', step: 1, min: -100 },
];
export const paperFields: readonly NumberField[] = [
  { key: 'width', label: 'width', testId: 'width-input', step: 1, min: 1 },
  { key: 'height', label: 'height', testId: 'height-input', step: 1, min: 1 },
  { key: 'top_margin', label: 'marginTop', testId: 'margin-top-input', step: 1, min: 0 },
  { key: 'bottom_margin', label: 'marginBottom', testId: 'margin-bottom-input', step: 1, min: 0 },
  { key: 'left_margin', label: 'marginLeft', testId: 'margin-left-input', step: 1, min: 0 },
  { key: 'right_margin', label: 'marginRight', testId: 'margin-right-input', step: 1, min: 0 },
];
export const variationFields: readonly NumberField[] = [
  {
    key: 'font_size_sigma',
    label: 'fontSizeSigma',
    testId: 'font-size-sigma-input',
    step: 0.5,
    min: 0,
  },
  {
    key: 'line_spacing_sigma',
    label: 'lineSpacingSigma',
    testId: 'line-spacing-sigma-input',
    step: 0.5,
    min: 0,
  },
  {
    key: 'word_spacing_sigma',
    label: 'wordSpacingSigma',
    testId: 'word-spacing-sigma-input',
    step: 0.5,
    min: 0,
  },
  {
    key: 'perturb_x_sigma',
    label: 'perturbXSigma',
    testId: 'perturb-x-sigma-input',
    step: 0.5,
    min: 0,
  },
  {
    key: 'perturb_y_sigma',
    label: 'perturbYSigma',
    testId: 'perturb-y-sigma-input',
    step: 0.5,
    min: 0,
  },
  {
    key: 'perturb_theta_sigma',
    label: 'perturbThetaSigma',
    testId: 'perturb-theta-sigma-input',
    step: 0.01,
    min: 0,
  },
  {
    key: 'ink_depth_sigma',
    label: 'inkDepthSigma',
    testId: 'ink-depth-sigma-input',
    step: 1,
    min: 0,
  },
];
export const strikeFields: readonly NumberField[] = [
  {
    key: 'strikethrough_probability',
    label: 'strikeProbability',
    testId: 'strikethrough-probability-input',
    step: 0.001,
    min: 0,
  },
  {
    key: 'strikethrough_width',
    label: 'strikeWidth',
    testId: 'strikethrough-width-input',
    step: 1,
    min: 0,
  },
  {
    key: 'strikethrough_length_sigma',
    label: 'strikeLength',
    testId: 'strikethrough-length-input',
    step: 1,
    min: 0,
  },
  {
    key: 'strikethrough_width_sigma',
    label: 'strikeWidthSigma',
    testId: 'strikethrough-width-sigma-input',
    step: 1,
    min: 0,
  },
  {
    key: 'strikethrough_angle_sigma',
    label: 'strikeAngle',
    testId: 'strikethrough-angle-input',
    step: 1,
    min: 0,
  },
];
export const allFields = [...mainFields, ...paperFields, ...variationFields, ...strikeFields];

const integerFields = new Set<NumericKey>([
  'font_size',
  'line_spacing',
  'word_spacing',
  'width',
  'height',
  'top_margin',
  'bottom_margin',
  'left_margin',
  'right_margin',
]);
export function validNumber(key: NumericKey, value: number): boolean {
  const field = allFields.find((item) => item.key === key);
  const maximum = key === 'strikethrough_probability' ? 1 : key === 'font_size' ? 2048 : 10000;
  return Boolean(
    field &&
    Number.isFinite(value) &&
    value >= field.min &&
    value <= maximum &&
    (!integerFields.has(key) || Number.isInteger(value)),
  );
}
export function validPaper(numbers: typeof defaultNumbers): boolean {
  return (
    numbers.font_size <= numbers.line_spacing &&
    numbers.word_spacing > -numbers.font_size / 2 &&
    numbers.left_margin + numbers.right_margin + numbers.font_size <= numbers.width &&
    numbers.top_margin + numbers.bottom_margin + numbers.line_spacing <= numbers.height &&
    numbers.width * numbers.height <= 16_000_000
  );
}
