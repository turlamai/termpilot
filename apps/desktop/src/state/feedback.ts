// Feedback primitives: promise-based in-app confirm and transient
// toasts. window.confirm/alert never appear in a commercial UI — they
// break the material system and cannot be themed.

import { create } from 'zustand';

interface ConfirmState {
  open: boolean;
  message: string;
  danger: boolean;
  confirmLabel: string;
  resolve: ((ok: boolean) => void) | null;
}

interface ToastState {
  toasts: { id: number; text: string; error: boolean }[];
  seq: number;
}

interface FeedbackState extends ConfirmState, ToastState {
  ask: (message: string, opts?: { danger?: boolean; confirmLabel?: string }) => Promise<boolean>;
  answer: (ok: boolean) => void;
  toast: (text: string, opts?: { error?: boolean }) => void;
  dismiss: (id: number) => void;
}

export const useFeedback = create<FeedbackState>((set, get) => ({
  open: false,
  message: '',
  danger: false,
  confirmLabel: '',
  resolve: null,
  toasts: [],
  seq: 0,

  ask: (message, opts) =>
    new Promise<boolean>((resolve) => {
      // One dialog at a time: an in-flight ask resolves false.
      get().resolve?.(false);
      set({
        open: true,
        message,
        danger: opts?.danger ?? false,
        confirmLabel: opts?.confirmLabel ?? '',
        resolve,
      });
    }),

  answer: (ok) => {
    const { resolve } = get();
    resolve?.(ok);
    set({ open: false, resolve: null });
  },

  toast: (text, opts) => {
    const id = get().seq + 1;
    set({
      seq: id,
      toasts: [...get().toasts, { id, text, error: opts?.error ?? false }],
    });
    setTimeout(() => get().dismiss(id), opts?.error ? 5000 : 2600);
  },

  dismiss: (id) =>
    set({ toasts: get().toasts.filter((t) => t.id !== id) }),
}));

/** Promise-flavored confirm for call sites. */
export function confirmDialog(
  message: string,
  opts?: { danger?: boolean; confirmLabel?: string },
): Promise<boolean> {
  return useFeedback.getState().ask(message, opts);
}

/** Fire-and-forget toast. */
export function toast(text: string, opts?: { error?: boolean }): void {
  useFeedback.getState().toast(text, opts);
}
