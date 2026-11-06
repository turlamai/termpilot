// Shared UI helpers.

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
