import { useCallback, useEffect, useRef, useState } from 'react';
import * as v from 'valibot';
import { useI18n } from '../i18n';
import { allFields, defaultNumbers, validNumber, validPaper } from '../models';
import type { NumericKey } from '../models';
import { migrateLegacySettings, readLegacySettings } from './legacySettings';
import { collapseInlineImages, expandInlineImages } from '@/utils/inlineImageManager';
const taskSchema = v.object({
  task_status: v.string(),
  task_message: v.optional(v.string()),
  task_progress: v.optional(v.number()),
  error_message: v.optional(v.string()),
  queue_pending_count: v.optional(v.nullable(v.number())),
  queue_ahead_count: v.optional(v.nullable(v.number())),
  processing_count: v.optional(v.nullable(v.number())),
});
const createSchema = v.object({ task_id: v.string() });
const errorSchema = v.object({
  message: v.optional(v.string()),
  error: v.optional(v.string()),
  status: v.optional(v.string()),
  estimated_wait_seconds: v.optional(v.number()),
});
const marginsSchema = v.object({
  marginLeft: v.number(),
  marginRight: v.number(),
  marginTop: v.number(),
  marginBottom: v.number(),
  lineSpacing: v.number(),
});
const settingsSchema = v.record(v.string(), v.union([v.number(), v.string(), v.boolean()]));
class RequestError extends Error {
  constructor(
    message: string,
    readonly retryAfter = 0,
  ) {
    super(message);
  }
}
async function checked(response: Response, fallback: string): Promise<Response> {
  if (response.ok) return response;
  const parsed = v.safeParse(errorSchema, await response.json().catch(() => ({})));
  if (parsed.success)
    throw new RequestError(
      parsed.output.message ?? parsed.output.error ?? fallback,
      parsed.output.status === 'queue_full' ? (parsed.output.estimated_wait_seconds ?? 30) : 0,
    );
  throw new Error(fallback);
}

function storedDraft() {
  try {
    const raw = localStorage.getItem('studio.draft') ?? localStorage.getItem('text');
    return raw ? v.parse(v.string(), JSON.parse(raw)) : '';
  } catch {
    return '';
  }
}
interface StudioState {
  text: string;
  imageStore: Record<string, string>;
  numbers: typeof defaultNumbers;
  fonts: string[];
  selectedFont: string;
  fontFile: File | null;
  background: File | null;
  backgroundUrl: string;
  textFileName: string;
  underlined: boolean;
  englishSpacing: boolean;
  fullPreview: boolean;
  ink: string;
  busy: boolean;
  notice: string;
  error: string;
  progress: number;
  retrySeconds: number;
  images: string[];
  currentPage: number;
  pdfBytes: number;
  version: string;
  savedPath: string;
  selectedPreset: string;
}
function initialState(): StudioState {
  const draft = collapseInlineImages(storedDraft());
  const initial: StudioState = {
    text: draft.collapsedText,
    imageStore: draft.imageStore,
    numbers: { ...defaultNumbers },
    fonts: [],
    selectedFont: '',
    fontFile: null,
    background: null,
    backgroundUrl: '',
    textFileName: '',
    underlined: true,
    englishSpacing: false,
    fullPreview: false,
    ink: '#26322a',
    busy: false,
    notice: '',
    error: '',
    progress: 0,
    retrySeconds: 0,
    images: [],
    currentPage: 0,
    pdfBytes: 0,
    version: '',
    savedPath: '',
    selectedPreset: '',
  };
  try {
    const raw = localStorage.getItem('studio.settings');
    const legacy = raw ? null : readLegacySettings();
    return raw
      ? parseSettings(raw, initial)
      : legacy
        ? parseSettings(migrateLegacySettings(legacy, []), initial)
        : initial;
  } catch {
    return initial;
  }
}
function parseSettings(raw: string, previous: StudioState): StudioState {
  const parsed = v.parse(settingsSchema, JSON.parse(raw));
  const next = { ...previous, numbers: { ...previous.numbers } };
  for (const field of allFields) {
    const value = parsed[field.key];
    if (value !== undefined) {
      if (typeof value !== 'number' || !validNumber(field.key, value))
        throw new Error('Invalid numeric preset');
      next.numbers[field.key] = value;
    }
  }
  if (!validPaper(next.numbers)) throw new Error('Invalid paper preset');
  const font = parsed['font'];
  if (typeof font === 'string' && (next.fonts.length === 0 || next.fonts.includes(font)))
    next.selectedFont = font;
  const underlined = parsed['underlined'];
  if (typeof underlined === 'boolean') next.underlined = underlined;
  const english = parsed['englishSpacing'];
  if (typeof english === 'boolean') next.englishSpacing = english;
  const ink = parsed['ink'];
  if (typeof ink === 'string' && /^#[\da-f]{6}$/i.test(ink)) next.ink = ink;
  const fullPreview = parsed['fullPreview'];
  if (typeof fullPreview === 'boolean') next.fullPreview = fullPreview;
  const textFileName = parsed['textFileName'];
  if (typeof textFileName === 'string') next.textFileName = textFileName;
  const text = parsed['text'];
  if (typeof text === 'string') {
    const draft = collapseInlineImages(text);
    next.text = draft.collapsedText;
    next.imageStore = draft.imageStore;
  }
  return next;
}
export function useWorkspace() {
  const { t } = useI18n();
  const [state, setState] = useState<StudioState>(initialState);
  const activeSocket = useRef<WebSocket | null>(null);
  const imageUrls = useRef<string[]>([]);
  const backgroundUrl = useRef('');
  const serverFonts = useRef<string[]>([]);
  const legacyFontSettings = useRef<string | null>(null);
  const legacyFontRead = useRef(false);
  if (!legacyFontRead.current) {
    try {
      legacyFontSettings.current = localStorage.getItem('studio.settings')
        ? null
        : readLegacySettings();
    } catch {
      /* Storage is optional. */
    }
    legacyFontRead.current = true;
  }
  const patch = useCallback(
    (values: Partial<StudioState>) => setState((previous) => ({ ...previous, ...values })),
    [],
  );
  const inform = useCallback((notice: string) => patch({ notice, error: '' }), [patch]);
  const fail = useCallback(
    (cause: unknown) =>
      patch({ error: cause instanceof Error ? cause.message : t('networkError'), notice: '' }),
    [patch, t],
  );
  function store(key: string, value: string): boolean {
    try {
      localStorage.setItem(key, value);
      return true;
    } catch {
      inform(t('storageUnavailable'));
      return false;
    }
  }

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    async function load() {
      try {
        const response = await checked(
          await fetch('/api/fonts_info', { signal: controller.signal }),
          t('networkError'),
        );
        const fonts = v.parse(v.array(v.string()), await response.json());
        if (active) serverFonts.current = fonts;
        if (active)
          setState((previous) => {
            const availableFonts =
              previous.fontFile && !fonts.includes(previous.fontFile.name)
                ? [...fonts, previous.fontFile.name]
                : fonts;
            const next = {
              ...previous,
              fonts: availableFonts,
              selectedFont: availableFonts.includes(previous.selectedFont)
                ? previous.selectedFont
                : (availableFonts[0] ?? ''),
            };
            try {
              const raw = localStorage.getItem('studio.settings');
              const restored = raw ? parseSettings(raw, next) : next;
              if (legacyFontSettings.current) {
                const legacy = parseSettings(
                  migrateLegacySettings(legacyFontSettings.current, availableFonts),
                  restored,
                );
                legacyFontSettings.current = null;
                return { ...restored, selectedFont: legacy.selectedFont };
              }
              return restored;
            } catch {
              return next;
            }
          });
      } catch (cause) {
        if (active) fail(cause);
      }
      try {
        const response = await fetch('/api/version', { signal: controller.signal });
        if (response.ok) {
          const version = v.parse(v.object({ version: v.string() }), await response.json()).version;
          if (active) patch({ version });
        }
      } catch {
        /* Supplementary version information. */
      }
    }
    void load();
    window.handwritingDesktop?.onDownloadFinished((payload) => {
      if (active) patch({ savedPath: payload.state === 'completed' ? payload.file : '' });
    });
    return () => {
      active = false;
      controller.abort();
    };
  }, [fail, patch, t]);
  useEffect(() => {
    try {
      localStorage.setItem(
        'studio.draft',
        JSON.stringify(expandInlineImages(state.text, state.imageStore)),
      );
    } catch {
      /* Editing works without storage. */
    }
  }, [state.text, state.imageStore]);
  useEffect(() => {
    try {
      localStorage.setItem(
        'studio.settings',
        JSON.stringify({
          ...state.numbers,
          font: state.selectedFont,
          underlined: state.underlined,
          englishSpacing: state.englishSpacing,
          ink: state.ink,
          fullPreview: state.fullPreview,
          textFileName: state.textFileName,
        }),
      );
    } catch {
      /* Settings remain available in memory. */
    }
  }, [
    state.numbers,
    state.selectedFont,
    state.underlined,
    state.englishSpacing,
    state.ink,
    state.fullPreview,
    state.textFileName,
  ]);
  useEffect(() => {
    if (state.retrySeconds <= 0) return;
    const timer = setTimeout(
      () =>
        setState((previous) => ({
          ...previous,
          retrySeconds: Math.max(0, previous.retrySeconds - 1),
        })),
      1000,
    );
    return () => clearTimeout(timer);
  }, [state.retrySeconds]);
  useEffect(
    () => () => {
      activeSocket.current?.close();
      for (const url of imageUrls.current) if (url.startsWith('blob:')) URL.revokeObjectURL(url);
      if (backgroundUrl.current) URL.revokeObjectURL(backgroundUrl.current);
    },
    [],
  );
  function setText(text: string) {
    setState((previous) => {
      if (text.includes('data:image/')) {
        const collapsed = collapseInlineImages(text, previous.imageStore);
        return { ...previous, text: collapsed.collapsedText, imageStore: collapsed.imageStore };
      }
      return { ...previous, text };
    });
  }
  function setNumber(key: NumericKey, value: number) {
    setState((previous) => ({ ...previous, numbers: { ...previous.numbers, [key]: value } }));
  }
  function saveSettings() {
    if (
      store(
        'studio.preset',
        JSON.stringify({
          text: expandInlineImages(state.text, state.imageStore),
          ...state.numbers,
          font: state.selectedFont,
          underlined: state.underlined,
          englishSpacing: state.englishSpacing,
          ink: state.ink,
          fullPreview: state.fullPreview,
          textFileName: state.textFileName,
        }),
      )
    )
      inform(t('saved'));
  }
  function loadSettings() {
    try {
      const modern = localStorage.getItem('studio.preset');
      const old = modern ? null : localStorage.getItem('myPreset');
      const raw = modern ?? (old ? migrateLegacySettings(old, state.fonts) : null);
      if (!raw) {
        inform(t('noPreset'));
        return;
      }
      const next = parseSettings(raw, state);
      if (old) store('studio.preset', raw);
      setState({ ...next, notice: t('loaded'), error: '' });
    } catch {
      fail(new Error(t('invalidPreset')));
    }
  }
  function resetSettings() {
    removeBackground();
    patch({
      numbers: { ...defaultNumbers },
      fontFile: null,
      fonts: serverFonts.current,
      selectedFont: serverFonts.current[0] ?? '',
      notice: '',
      error: '',
      images: [],
      currentPage: 0,
      underlined: true,
      englishSpacing: false,
      ink: '#26322a',
      selectedPreset: '',
    });
  }
  function applyPreset(value: string) {
    if (state.background) {
      inform(t('presetBackground'));
      return;
    }
    const numbers = { ...defaultNumbers };
    let font = state.selectedFont;
    let underlined = state.underlined;
    if (value === 'smallUnderlined') {
      Object.assign(numbers, {
        font_size: 70,
        line_spacing: 100,
        width: 2481,
        height: 3507,
        top_margin: 150,
        bottom_margin: 150,
        left_margin: 150,
        right_margin: 150,
        line_spacing_sigma: 1,
        font_size_sigma: 1,
        word_spacing_sigma: 2,
        perturb_x_sigma: 1,
        perturb_y_sigma: 1,
        perturb_theta_sigma: 0.05,
        word_spacing: 2,
        strikethrough_probability: 0,
      });
      font = state.fonts.find((item) => item === '云烟体.ttf') ?? font;
      underlined = true;
    } else if (value === 'clean') {
      Object.assign(numbers, {
        font_size_sigma: 0,
        word_spacing_sigma: 0,
        perturb_x_sigma: 0,
        perturb_y_sigma: 0,
        perturb_theta_sigma: 0,
        strikethrough_probability: 0,
      });
    }
    patch({
      numbers,
      selectedFont: font,
      underlined,
      ...(value === 'smallUnderlined' ? { englishSpacing: false, fontFile: null } : {}),
      selectedPreset: value,
      notice: t('presetApplied'),
      error: '',
    });
  }
  async function importText(file: File) {
    try {
      const data = new FormData();
      data.append('file', file);
      const response = await checked(
        await fetch('/api/textfileprocess', { method: 'POST', body: data }),
        t('networkError'),
      );
      const text = v.parse(v.object({ text: v.string() }), await response.json()).text;
      setText(text);
      patch({ textFileName: file.name, notice: t('uploaded'), error: '' });
    } catch (cause) {
      fail(cause);
    }
  }
  function useFont(file: File) {
    setState((previous) => ({
      ...previous,
      fontFile: file,
      fonts: previous.fonts.includes(file.name) ? previous.fonts : [...previous.fonts, file.name],
      selectedFont: file.name,
    }));
  }
  function useBackground(file: File) {
    if (backgroundUrl.current) URL.revokeObjectURL(backgroundUrl.current);
    const url = URL.createObjectURL(file);
    backgroundUrl.current = url;
    patch({
      background: file,
      backgroundUrl: url,
      images: [],
      currentPage: 0,
      notice: t('backgroundLoaded'),
      error: '',
    });
  }
  function removeBackground() {
    if (backgroundUrl.current) URL.revokeObjectURL(backgroundUrl.current);
    backgroundUrl.current = '';
    patch({ background: null, backgroundUrl: '' });
  }
  async function detectBackground() {
    if (!state.background) return;
    try {
      const data = new FormData();
      data.append('file', state.background);
      const response = await checked(
        await fetch('/api/imagefileprocess', { method: 'POST', body: data }),
        t('networkError'),
      );
      const margins = v.parse(marginsSchema, await response.json());
      setState((previous) => ({
        ...previous,
        numbers: {
          ...previous.numbers,
          left_margin: margins.marginLeft,
          right_margin: margins.marginRight,
          top_margin: Math.max(0, margins.marginTop - previous.numbers.line_spacing),
          bottom_margin: margins.marginBottom,
          line_spacing: margins.lineSpacing,
        },
        notice: t('backgroundLoaded'),
        error: '',
      }));
    } catch (cause) {
      fail(cause);
    }
  }
  function updateTask(task: v.InferOutput<typeof taskSchema>) {
    const details =
      task.task_status === 'pending'
        ? [
            typeof task.queue_ahead_count === 'number'
              ? `${t('queueAhead')} ${task.queue_ahead_count}`
              : '',
            typeof task.queue_pending_count === 'number'
              ? `${t('queuePending')} ${task.queue_pending_count}`
              : '',
            typeof task.processing_count === 'number'
              ? `${t('queueProcessing')} ${task.processing_count}`
              : '',
          ].filter(Boolean)
        : [];
    patch({
      progress: task.task_progress ?? 0,
      ...(task.task_message || details.length
        ? { notice: [task.task_message, ...details].filter(Boolean).join(' · ') }
        : {}),
    });
  }
  async function waitTask(id: string) {
    try {
      await new Promise<void>((resolve, reject) => {
        const address = new URL(
          `/api/generate_handwriting/ws/${encodeURIComponent(id)}`,
          window.location.href,
        );
        address.protocol = address.protocol === 'https:' ? 'wss:' : 'ws:';
        const socket = new WebSocket(address);
        activeSocket.current = socket;
        const timer = setTimeout(() => finish(new Error(t('timeout'))), 300_000);
        function finish(cause?: Error) {
          clearTimeout(timer);
          socket.onclose = null;
          socket.close();
          activeSocket.current = null;
          if (cause) reject(cause);
          else resolve();
        }
        socket.onmessage = (event: MessageEvent<unknown>) => {
          if (typeof event.data !== 'string') return;
          try {
            const task = v.parse(taskSchema, JSON.parse(event.data));
            updateTask(task);
            if (task.task_status === 'completed') finish();
            if (task.task_status === 'failed')
              finish(new Error(task.error_message ?? task.task_message ?? t('taskFailed')));
          } catch (cause) {
            finish(cause instanceof Error ? cause : new Error(t('invalidResponse')));
          }
        };
        socket.onerror = () => finish(new Error(t('networkError')));
        socket.onclose = () => finish(new Error(t('networkError')));
      });
    } catch {
      for (let attempt = 0; attempt < 200; attempt++) {
        const response = await checked(
          await fetch(`/api/generate_handwriting/task/${encodeURIComponent(id)}`),
          t('networkError'),
        );
        const task = v.parse(taskSchema, await response.json());
        updateTask(task);
        if (task.task_status === 'completed') return;
        if (task.task_status === 'failed')
          throw new Error(task.error_message ?? task.task_message ?? t('taskFailed'));
        await new Promise<void>((resolve) => setTimeout(resolve, 1500));
      }
      throw new Error(t('timeout'));
    }
  }
  async function generate(mode: 'preview' | 'zip' | 'pdf') {
    if (state.busy || state.retrySeconds > 0) return;
    if (!state.text.trim()) {
      fail(new Error(t('emptyText')));
      return;
    }
    if (state.numbers.font_size > state.numbers.line_spacing) {
      fail(new Error(t('invalidSize')));
      return;
    }
    if (!allFields.every((field) => validNumber(field.key, state.numbers[field.key]))) {
      fail(new Error(t('invalidNumber')));
      return;
    }
    if (!state.background && !validPaper(state.numbers)) {
      fail(new Error(t('invalidPaper')));
      return;
    }
    patch({ busy: true, progress: 0, notice: t('working'), error: '' });
    try {
      const data = new FormData();
      data.append('text', expandInlineImages(state.text, state.imageStore));
      for (const [key, value] of Object.entries(state.numbers)) {
        if (state.background && (key === 'width' || key === 'height')) continue;
        data.append(key, String(value));
      }
      data.append('font_option', state.selectedFont);
      if (state.fontFile?.name === state.selectedFont) data.append('font_file', state.fontFile);
      data.append('background_image', state.background ?? '');
      const rgb = state.ink.match(/[\da-f]{2}/gi)?.map((value) => Number.parseInt(value, 16)) ?? [
        0, 0, 0,
      ];
      data.append('fill', `(${rgb.join(',')},255)`);
      data.append('preview', String(mode === 'preview'));
      data.append('pdf_save', String(mode === 'pdf'));
      data.append('full_preview', String(mode === 'preview' && state.fullPreview));
      data.append('isUnderlined', String(state.underlined));
      data.append('enableEnglishSpacing', String(state.englishSpacing));
      const created = await checked(
        await fetch('/api/generate_handwriting', { method: 'POST', body: data }),
        t('networkError'),
      );
      const id = v.parse(createSchema, await created.json()).task_id;
      await waitTask(id);
      const response = await checked(
        await fetch(`/api/generate_handwriting/task/${encodeURIComponent(id)}/result`),
        t('networkError'),
      );
      const type = response.headers.get('content-type') ?? '';
      if (mode === 'preview') {
        let images: string[];
        if (type.includes('json')) {
          const result = v.parse(v.object({ images: v.array(v.string()) }), await response.json());
          images = result.images.map((image) => `data:image/png;base64,${image}`);
        } else if (type.includes('image/')) images = [URL.createObjectURL(await response.blob())];
        else throw new Error(t('invalidResponse'));
        for (const url of imageUrls.current) if (url.startsWith('blob:')) URL.revokeObjectURL(url);
        imageUrls.current = images;
        patch({ images, currentPage: 0, notice: t('previewLoaded'), error: '' });
      } else {
        const blob = await response.blob();
        patch({ savedPath: '', ...(mode === 'pdf' ? { pdfBytes: blob.size } : {}) });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = mode === 'pdf' ? 'images.pdf' : 'images.zip';
        document.body.append(link);
        link.click();
        link.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
        inform(t(window.handwritingDesktop ? 'downloadDesktop' : 'downloadBrowser'));
      }
    } catch (cause) {
      if (cause instanceof RequestError && cause.retryAfter > 0)
        patch({ retrySeconds: Math.ceil(cause.retryAfter), error: '', notice: '' });
      else fail(cause);
    } finally {
      patch({ busy: false });
    }
  }
  return {
    ...state,
    disabled: state.busy || state.retrySeconds > 0 || state.fonts.length === 0,
    patch,
    setText,
    setNumber,
    inform,
    fail,
    saveSettings,
    loadSettings,
    resetSettings,
    applyPreset,
    importText,
    useFont,
    useBackground,
    removeBackground,
    detectBackground,
    generate,
  };
}
export type Workspace = ReturnType<typeof useWorkspace>;
