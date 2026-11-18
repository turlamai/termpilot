// Shared UI helpers.

import type { Lang } from './i18n';
import { translate } from './i18n';

/** The backend classifies serial open failures into contract states
    (device-busy / no-access / not-present) and embeds the keyword in
    the error message; surface the matching recovery guidance. */
export function serialFaultText(lang: Lang, err: unknown): string | null {
  const msg = String(err);
  const key = msg.includes('device-busy')
    ? 'serial.fault.busy'
    : msg.includes('no-access')
      ? 'serial.fault.no-access'
      : msg.includes('not-present')
        ? 'serial.fault.not-present'
        : null;
  return key ? translate(lang, key) : null;
}

/** Arrow-key navigation within a picker list: focus moves between
    buttons, Enter activates (native button behavior). Attach to the
    list container's onKeyDown. */
export function pickerKeyNav(e: React.KeyboardEvent): void {
  if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
  e.preventDefault();
  const container = e.currentTarget as HTMLElement;
  const buttons = [
    ...container.querySelectorAll<HTMLButtonElement>('.picker-row'),
  ];
  if (buttons.length === 0) return;
  const idx = buttons.indexOf(document.activeElement as HTMLButtonElement);
  const next =
    e.key === 'ArrowDown'
      ? buttons[(idx + 1) % buttons.length]
      : buttons[(idx - 1 + buttons.length) % buttons.length];
  next.focus();
}
