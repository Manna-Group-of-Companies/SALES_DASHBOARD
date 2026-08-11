/**
 * The route on a customer or lead, assignable in place.
 *
 * The dropdown offers **only the owning rep's routes**. A route is named
 * `<Rep> - <Place>` and belongs to one person, so putting Prashanth's customer
 * on Bibin's run is never the intended action — and with 98 routes on the
 * site, an unfiltered list makes that mistake easy and quiet.
 *
 * A party with no rep gets no dropdown at all: there is no correct answer to
 * offer, and assigning a route to an unowned record just moves the problem.
 */

import { useState } from 'react';
import type { SalesRoute } from '@/domain/types';
import { hasRoute } from '@/domain/sales';
import { Api } from '@/api/client';
import { Badge, Select } from '@/components/ui';

export function RouteCell({
  kind,
  id,
  rep,
  route,
  routes,
  onSaved,
  onError,
}: {
  kind: 'customer' | 'lead';
  id: string;
  rep?: string;
  route?: string;
  routes: SalesRoute[];
  onSaved: (route: string) => void;
  onError: (message: string) => void;
}) {
  const [saving, setSaving] = useState(false);

  const mine = routes.filter((r) => r.rep === rep);

  if (hasRoute(route)) {
    return <span className="small">{route}</span>;
  }

  if (!rep) {
    return (
      <Badge tone="warn" title="Assign a representative before a route">
        no rep
      </Badge>
    );
  }

  if (mine.length === 0) {
    return (
      <Badge tone="warn" title={`${rep} has no routes defined in ERPNext`}>
        no routes for {rep}
      </Badge>
    );
  }

  const assign = async (value: string) => {
    if (!value) return;
    setSaving(true);
    try {
      await Api.sales.assignRoute({ kind, id, route: value });
      onSaved(value);
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not assign the route.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Select
      compact
      value=""
      disabled={saving}
      onChange={(e) => assign(e.target.value)}
      aria-label={`Assign a route for ${id}`}
      title={`${rep}'s routes`}
    >
      <option value="">{saving ? 'Saving…' : 'Assign route…'}</option>
      {mine.map((r) => (
        <option key={r.id} value={r.id}>
          {r.name}
        </option>
      ))}
    </Select>
  );
}
