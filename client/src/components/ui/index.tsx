/**
 * Shared presentational primitives.
 *
 * Deliberately small and unopinionated — they carry the design tokens and the
 * accessibility plumbing (focus trap, escape-to-close, aria labelling) so the
 * feature screens can stay about the workflow.
 */

import {
  useEffect,
  useRef,
  type ButtonHTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
  type SelectHTMLAttributes,
  type TextareaHTMLAttributes,
} from 'react';
import './ui.css';

// ------------------------------------------------------------- Button ---

type ButtonVariant = 'default' | 'primary' | 'danger' | 'ghost';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: 'sm' | 'md' | 'lg';
  loading?: boolean;
  block?: boolean;
  iconOnly?: boolean;
}

export function Button({
  variant = 'default',
  size = 'md',
  loading = false,
  block = false,
  iconOnly = false,
  disabled,
  children,
  className = '',
  ...rest
}: ButtonProps) {
  const classes = [
    'btn',
    variant !== 'default' && `btn--${variant}`,
    size !== 'md' && `btn--${size}`,
    block && 'btn--block',
    iconOnly && 'btn--icon',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <button className={classes} disabled={disabled || loading} {...rest}>
      {loading && <span className="spinner" aria-hidden />}
      {children}
    </button>
  );
}

// -------------------------------------------------------------- Field ---

interface FieldProps {
  label?: string;
  hint?: string;
  error?: string;
  htmlFor?: string;
  children: ReactNode;
}

export function Field({ label, hint, error, htmlFor, children }: FieldProps) {
  return (
    <div className="field">
      {label && (
        <label className="field__label" htmlFor={htmlFor}>
          {label}
        </label>
      )}
      {children}
      {error ? (
        <span className="field__error" role="alert">
          {error}
        </span>
      ) : (
        hint && <span className="field__hint">{hint}</span>
      )}
    </div>
  );
}

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  invalid?: boolean;
  numeric?: boolean;
  compact?: boolean;
}

export function Input({ invalid, numeric, compact, className = '', ...rest }: InputProps) {
  const classes = [
    'input',
    numeric && 'input--num',
    compact && 'input--sm',
    invalid && 'input--invalid',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  return <input className={classes} aria-invalid={invalid || undefined} {...rest} />;
}

/** A number input with a unit stuck to its right edge — "28.5 kg", "12 rolls". */
export function UnitInput({
  suffix,
  invalid,
  compact,
  ...rest
}: InputProps & { suffix: string }) {
  return (
    <div className="input-group">
      <Input numeric invalid={invalid} compact={compact} {...rest} />
      <span className="input-group__suffix">{suffix}</span>
    </div>
  );
}

export function Select({
  className = '',
  compact,
  ...rest
}: SelectHTMLAttributes<HTMLSelectElement> & { compact?: boolean }) {
  return <select className={`select ${compact ? 'input--sm' : ''} ${className}`} {...rest} />;
}

export function Textarea({ className = '', ...rest }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={`textarea ${className}`} {...rest} />;
}

// --------------------------------------------------------------- Card ---

export function Card({
  title,
  actions,
  children,
  footer,
  flush = false,
  className = '',
}: {
  title?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  flush?: boolean;
  className?: string;
}) {
  return (
    <section className={`card ${className}`}>
      {(title || actions) && (
        <header className="card__header">
          <div className="card__title grow">{title}</div>
          {actions}
        </header>
      )}
      <div className={`card__body ${flush ? 'card__body--flush' : ''}`}>{children}</div>
      {footer && <footer className="card__footer">{footer}</footer>}
    </section>
  );
}

// -------------------------------------------------------------- Badge ---

export type BadgeTone = 'neutral' | 'info' | 'ok' | 'warn' | 'danger' | 'accent';

export function Badge({
  tone = 'neutral',
  dot = false,
  children,
  title,
}: {
  tone?: BadgeTone;
  dot?: boolean;
  children: ReactNode;
  title?: string;
}) {
  return (
    <span className={`badge badge--${tone}`} title={title}>
      {dot && <span className="badge__dot" aria-hidden />}
      {children}
    </span>
  );
}

// -------------------------------------------------------------- Alert ---

export function Alert({
  tone = 'info',
  title,
  icon,
  children,
  actions,
}: {
  tone?: 'info' | 'ok' | 'warn' | 'danger';
  title?: string;
  icon?: ReactNode;
  children?: ReactNode;
  actions?: ReactNode;
}) {
  const fallbackIcon = { info: 'ℹ', ok: '✓', warn: '⚠', danger: '⚠' }[tone];
  return (
    <div className={`alert alert--${tone}`} role={tone === 'danger' ? 'alert' : undefined}>
      <span className="alert__icon" aria-hidden>
        {icon ?? fallbackIcon}
      </span>
      <div className="grow">
        {title && <div className="alert__title">{title}</div>}
        {children}
      </div>
      {actions}
    </div>
  );
}

// -------------------------------------------------------------- Modal ---

export function Modal({
  title,
  onClose,
  children,
  footer,
  width = 'md',
}: {
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  width?: 'md' | 'wide' | 'xwide';
}) {
  const ref = useRef<HTMLDivElement>(null);

  // Escape closes, and focus starts inside the dialog rather than behind it.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKey);
    const previous = document.activeElement as HTMLElement | null;
    ref.current?.querySelector<HTMLElement>('input, select, textarea, button')?.focus();
    return () => {
      document.removeEventListener('keydown', onKey);
      previous?.focus();
    };
  }, [onClose]);

  const widthClass = width === 'md' ? '' : `modal--${width}`;

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className={`modal ${widthClass}`} role="dialog" aria-modal="true" ref={ref}>
        <header className="modal__header">
          <div className="modal__title grow">{title}</div>
          <Button variant="ghost" size="sm" iconOnly onClick={onClose} aria-label="Close">
            ✕
          </Button>
        </header>
        <div className="modal__body">{children}</div>
        {footer && <footer className="modal__footer">{footer}</footer>}
      </div>
    </div>
  );
}

// --------------------------------------------------------------- Tabs ---

export interface TabDef<T extends string> {
  id: T;
  label: string;
  count?: number;
}

export function Tabs<T extends string>({
  tabs,
  active,
  onChange,
}: {
  tabs: TabDef<T>[];
  active: T;
  onChange: (id: T) => void;
}) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((t) => (
        <button
          key={t.id}
          role="tab"
          aria-selected={t.id === active}
          className={`tab ${t.id === active ? 'is-active' : ''}`}
          onClick={() => onChange(t.id)}
        >
          {t.label}
          {t.count != null && <span className="tab__count">{t.count}</span>}
        </button>
      ))}
    </div>
  );
}

// ------------------------------------------------------------ Segmented ---

export function Segmented<T extends string>({
  options,
  value,
  onChange,
  ariaLabel,
}: {
  options: Array<{ value: T; label: string }>;
  value: T;
  onChange: (v: T) => void;
  ariaLabel?: string;
}) {
  return (
    <div className="segmented" role="radiogroup" aria-label={ariaLabel}>
      {options.map((o) => (
        <button
          key={o.value}
          role="radio"
          aria-checked={o.value === value}
          className={`segmented__btn ${o.value === value ? 'is-active' : ''}`}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

// -------------------------------------------------------------- Meter ---

export function Meter({
  value,
  tone = 'accent',
  label,
}: {
  /** 0–1. */
  value: number;
  tone?: 'accent' | 'ok' | 'warn' | 'danger';
  label?: string;
}) {
  const pct = Math.max(0, Math.min(1, value)) * 100;
  return (
    <div
      className="meter"
      role="progressbar"
      aria-valuenow={Math.round(pct)}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={label}
    >
      <div
        className={`meter__fill ${tone !== 'accent' ? `meter__fill--${tone}` : ''}`}
        style={{ width: `${pct}%` }}
      />
    </div>
  );
}

// -------------------------------------------------------------- Empty ---

export function Empty({
  icon = '—',
  title,
  children,
  action,
}: {
  icon?: ReactNode;
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty__icon" aria-hidden>
        {icon}
      </div>
      <div className="empty__title">{title}</div>
      {children && <div className="small">{children}</div>}
      {action && <div style={{ marginTop: 8 }}>{action}</div>}
    </div>
  );
}

export function Skeleton({ height = 16, width = '100%' }: { height?: number; width?: number | string }) {
  return <div className="skeleton" style={{ height, width }} />;
}

export function Tooltip({ text, children }: { text: string; children: ReactNode }) {
  return (
    <span className="tip">
      {children}
      <span className="tip__body" role="tooltip">
        {text}
      </span>
    </span>
  );
}
