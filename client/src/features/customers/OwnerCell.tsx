/**
 * Who a customer or lead belongs to, assignable in place — UAE only.
 *
 * Everywhere else a customer has always belonged to one rep and reassignment
 * is not offered — see `canAssignOwner` in `domain/visibility.ts`. `peers` is
 * the pool this manager belongs to, already resolved by the caller; an empty
 * list means "not pooled" and this renders as plain text, exactly like an
 * unassigned record does everywhere outside UAE.
 */

import { useState } from 'react';
import { Api } from '@/api/client';
import { Badge, Select } from '@/components/ui';

export function OwnerCell({
  kind,
  id,
  owner,
  peers,
  onSaved,
  onError,
}: {
  kind: 'customer' | 'lead';
  id: string;
  owner?: string;
  /** The pool this manager may assign within. Empty means not pooled. */
  peers: string[];
  onSaved: (owner: string) => void;
  onError: (message: string) => void;
}) {
  const [saving, setSaving] = useState(false);

  if (peers.length === 0) {
    return owner ? <span className="dim">{owner}</span> : <Badge tone="warn">unassigned</Badge>;
  }

  const assign = async (value: string) => {
    if (!value || value === owner) return;
    setSaving(true);
    try {
      await Api.sales.assignOwner({ kind, id, rep: value });
      onSaved(value);
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not assign the rep.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Select
      compact
      value={owner ?? ''}
      disabled={saving}
      onChange={(e) => assign(e.target.value)}
      aria-label={`Assign a rep for ${id}`}
    >
      <option value="">{saving ? 'Saving…' : 'Unassigned'}</option>
      {peers.map((p) => (
        <option key={p} value={p}>
          {p}
        </option>
      ))}
    </Select>
  );
}
