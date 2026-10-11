import type { AttendanceStatus, LeaveStatus, OrderStatus } from '@/domain/types';
import { ATTENDANCE_LABEL, LEAVE_STATUS_LABEL, ORDER_STATUS_LABEL } from '@/domain/types';
import { Badge, type BadgeTone } from '@/components/ui';

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

/*
 * `FreezeChip` stood here until 11 October 2026: a countdown to 1:00 PM on the
 * delivery date, when orders used to stop taking changes. That cutoff is gone
 * — approval alone ends editing (order_locked_after_approval.json) — so there
 * is nothing left to count down to.
 */

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
