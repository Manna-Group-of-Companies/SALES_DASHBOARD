/**
 * Reload this screen's data from ERPNext.
 *
 * Every screen here reads live records that a rep, a manager or the field-sales
 * app may have changed a minute ago, so "is this current?" is a question the
 * user should always be able to settle themselves rather than by reloading the
 * whole page and losing their place.
 */

import { Button } from '@/components/ui';

export function RefreshButton({
  onClick,
  loading = false,
  label = 'Refresh',
}: {
  onClick: () => void;
  loading?: boolean;
  label?: string;
}) {
  return (
    <Button
      size="sm"
      variant="ghost"
      onClick={onClick}
      loading={loading}
      title="Reload from ERPNext"
      aria-label="Reload from ERPNext"
    >
      <span aria-hidden>↻</span> {label}
    </Button>
  );
}
