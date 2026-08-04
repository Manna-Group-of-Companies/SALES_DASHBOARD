/**
 * The headline number on a landing page.
 *
 * Every tile is a link to the screen where something can be done about it —
 * a number nobody can act on is not worth the space.
 */

export function Tile({
  label,
  value,
  foot,
  tone,
  onClick,
}: {
  label: string;
  value: string;
  foot?: string;
  tone?: 'ok' | 'warn' | 'alert';
  onClick?: () => void;
}) {
  return (
    <div
      className={`tile ${tone === 'alert' ? 'is-alert' : tone === 'warn' ? 'is-warn' : ''}`}
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={(e) => {
        if (onClick && (e.key === 'Enter' || e.key === ' ')) onClick();
      }}
      style={{ cursor: onClick ? 'pointer' : undefined }}
    >
      <div className="tile__label">{label}</div>
      <div className="tile__value" style={{ color: tone === 'ok' ? 'var(--ok)' : undefined }}>
        {value}
      </div>
      {foot && <div className="tile__foot">{foot}</div>}
    </div>
  );
}
