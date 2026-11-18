import { create } from 'zustand';
import { isDefault } from './fineEditModel';
import type { Adjustment, FineEdits } from './fineEditModel';

interface FineEditState {
  enabled: boolean;
  saved: FineEdits | null;
  undo: (FineEdits | null)[];
  redo: (FineEdits | null)[];
  sourceSelection: { text: string; start: number; end: number } | null;
  selectSource: (selection: FineEditState['sourceSelection']) => void;
  enable: () => void;
  restore: (saved: FineEdits | null) => void;
  apply: (text: string, key: string, values: readonly Adjustment[]) => void;
  step: (direction: 'undo' | 'redo') => void;
}

export const useFineEditStore = create<FineEditState>()((set) => ({
  enabled: false,
  saved: null,
  undo: [],
  redo: [],
  sourceSelection: null,
  selectSource: (sourceSelection) => set({ sourceSelection }),
  enable: () => set({ enabled: true }),
  restore: (saved) => set({ saved, enabled: Boolean(saved), undo: [], redo: [] }),
  apply: (text, key, values) =>
    set((state) => {
      const previous = state.saved?.key === key ? state.saved.glyphs : [];
      const edits = new Map(previous.map((value) => [value.id, value]));
      for (const value of values) {
        const current = edits.get(value.id);
        if (isDefault(value)) edits.delete(value.id);
        else if (!current || JSON.stringify(current) !== JSON.stringify(value))
          edits.set(value.id, value);
      }
      const glyphs = [...edits.values()];
      if (
        glyphs.length > 10_000 ||
        (glyphs.length === previous.length && glyphs.every((item, i) => item === previous[i]))
      )
        return state;
      return {
        saved: { text, key, glyphs },
        undo: [...state.undo.slice(-49), state.saved],
        redo: [],
      };
    }),
  step: (direction) =>
    set((state) => {
      const history = state[direction];
      if (!history.length) return state;
      const opposite = direction === 'undo' ? 'redo' : 'undo';
      return {
        saved: history.at(-1) ?? null,
        [direction]: history.slice(0, -1),
        [opposite]: [...state[opposite], state.saved],
      };
    }),
}));
