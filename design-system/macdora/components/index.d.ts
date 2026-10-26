/** Portable documentation controls; production controls are AppKit TFButton / TFToggleSwitch / TFSegmentedControl. */
declare namespace MacdoraUI {
  interface ButtonProps { label: string; variant?: 'primary'|'secondary'|'tinted'|'subtle'|'ghost'|'danger'; disabled?: boolean; ariaLabel?: string; onClick?: () => void; }
  function Button(props: ButtonProps): HTMLButtonElement;
  interface ToggleProps { label: string; checked?: boolean; disabled?: boolean; onChange?: (checked: boolean) => void; }
  function Toggle(props: ToggleProps): HTMLLabelElement;
  interface SegmentedControlProps { label: string; options: Array<{value: string; label: string}>; value: string; disabled?: boolean; onChange?: (value: string) => void; }
  function SegmentedControl(props: SegmentedControlProps): HTMLFieldSetElement;
  const Motion: { reveal(element: HTMLElement, reduceMotion?: boolean): void };
}
