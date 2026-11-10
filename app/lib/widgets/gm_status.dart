import 'package:flutter/material.dart';
import 'package:manna_field_sales/core/credit_commitment.dart';

const _withManager = {
  'Pending Approval',
  'PO Uploaded - Pending Approval',
  'Pending Rate Approval',
};

/// Whose desk an over-credit order is on, for the rep (10 Nov 2026): the
/// manager's, then the GM's, then GM approved. An order over the limit is the
/// one that carries the customer's promise ([commitment]); the manager can
/// only pass it on, so "With manager" means it has not reached the GM yet.
/// Null for every other order and status.
({String label, Color color, IconData icon})? gmStatusOf(String poStatus,
    {dynamic commitment}) {
  final po = poStatus.trim();
  if (_withManager.contains(po) && hasCommitment(commitment)) {
    return (
      label: 'With manager',
      color: const Color(0xFFE65100),
      icon: Icons.person_rounded,
    );
  }
  switch (po) {
    case 'Pending GM Approval':
      return (
        label: 'With GM',
        color: const Color(0xFF6A1B9A),
        icon: Icons.forward_to_inbox_rounded,
      );
    case 'Pending Final Approval':
      return (
        label: 'GM approved',
        color: const Color(0xFF2E7D32),
        icon: Icons.verified_rounded,
      );
  }
  return null;
}

/// A small coloured tag for the order lists.
class GmPill extends StatelessWidget {
  final String poStatus;
  final dynamic commitment;
  const GmPill({super.key, required this.poStatus, this.commitment});

  @override
  Widget build(BuildContext context) {
    final s = gmStatusOf(poStatus, commitment: commitment);
    if (s == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: s.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 13, color: s.color),
        const SizedBox(width: 4),
        Text(s.label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: s.color)),
      ]),
    );
  }
}

/// The locked proforma button while the credit waits (10 Nov 2026): whose
/// desk the order is on, instead of a banner at the top of the order page.
/// Once the GM approves, the proforma unlocks (proforma_release.dart) and this
/// is not shown.
String proformaHeldLabel(String poStatus) =>
    poStatus.trim() == 'Pending GM Approval'
        ? 'With GM · waiting for approval'
        : 'With manager';

/// Chat-style ticks for an order waiting on the manager or the GM:
/// one grey tick when sent, two blue ticks once a manager has opened it,
/// "With GM" once escalated. Null for every other status.
Widget? approvalTicks(String poStatus, dynamic managerSeenOn) {
  final po = poStatus.trim();
  final seen = '${managerSeenOn ?? ''}'.trim();
  const waiting = _withManager;
  Widget row(IconData icon, Color color, String text) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      ]);
  if (waiting.contains(po)) {
    return seen.isNotEmpty && seen != 'null'
        ? row(Icons.done_all_rounded, const Color(0xFF1E88E5), 'Seen by manager')
        : row(Icons.done_rounded, Colors.black45, 'Sent to manager');
  }
  if (po == 'Pending GM Approval') {
    return row(Icons.forward_to_inbox_rounded, const Color(0xFF6A1B9A), 'With GM');
  }
  return null;
}
