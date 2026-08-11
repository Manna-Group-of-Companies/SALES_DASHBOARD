import type { AttendanceStatus, LeaveStatus, Order, OrderStatus } from '@/domain/types';
import { ATTENDANCE_LABEL, LEAVE_STATUS_LABEL, ORDER_STATUS_LABEL } from '@/domain/types';
import { formatFreezeCountdown, freezeUrgency } from '@/domain/orderRules';
import { Badge, type BadgeTone, Tooltip } from '@/components/ui';

const TONE: Record<OrderStatus, BadgeTone> = {
  draft: 'neutral',
  pending_approval: 'warn',
  approved: 'info',
  in_production: 'accent',
  dispatched: 'ok',
  grouped: 'neutral',
  rejected: 'danger',
};

export function StatusBadge({ status }: { status: OrderStatus }) {
  return (
    <Badge tone={TONE[status]} dot>
      {ORDER_STATUS_LABEL[status]}
    </Badge>
  );
}

/**
 * The edit-freeze countdown (3.3). Sits on every order row so a rep can see at a
 * glance which orders they can still change — the deadline is easy to forget
 * and impossible to undo.
 */
export function FreezeChip({ order }: { order: Order }) {
  if (order.status === 'grouped' || order.status === 'rejected') return null;

  const urgency = freezeUrgency(order);
  const tone: BadgeTone =
    urgency === 'frozen' ? 'danger' : urgency === 'imminent' ? 'warn' : 'neutral';
  const label = formatFreezeCountdown(order);

  return (
    <Tooltip
      text={
        urgency === 'frozen'
          ? 'Edits closed at 1:00 PM on the delivery date.'
          : 'Edits close at 1:00 PM on the delivery date.'
      }
    >
      <Badge tone={tone}>{urgency === 'frozen' ? '🔒 Frozen' : `⏳ ${label}`}</Badge>
    </Tooltip>
  );
}

const ATTENDANCE_TONE: Record<AttendanceStatus, BadgeTone> = {
  present: 'ok',
  half_day: 'info',
  on_leave: 'accent',
  absent: 'danger',
  holiday: 'neutral',
};

/** `undefined` means nobody has marked this person yet — not that they are absent. */
export function AttendanceBadge({ status }: { status?: AttendanceStatus }) {
  if (!status) return <Badge tone="warn">Not marked</Badge>;
  return (
    <Badge tone={ATTENDANCE_TONE[status]} dot>
      {ATTENDANCE_LABEL[status]}
    </Badge>
  );
}

const LEAVE_TONE: Record<LeaveStatus, BadgeTone> = {
  pending: 'warn',
  approved: 'ok',
  rejected: 'danger',
  cancelled: 'neutral',
};

export function LeaveStatusBadge({ status }: { status: LeaveStatus }) {
  return (
    <Badge tone={LEAVE_TONE[status]} dot>
      {LEAVE_STATUS_LABEL[status]}
    </Badge>
  );
}

export function SourceBadge({ source }: { source?: 'min_stock' | 'new_production' }) {
  if (!source) return <span className="dim small">—</span>;
  return source === 'min_stock' ? (
    <Badge tone="ok">Min stock</Badge>
  ) : (
    <Badge tone="accent">New production</Badge>
  );
}
