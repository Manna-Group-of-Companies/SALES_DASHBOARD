import 'package:flutter/material.dart';

/// Where an order stands with the GM, for the rep: sent over the credit
/// limit, or approved by the GM. Null for every other status.
({String label, Color color, IconData icon})? gmStatusOf(String poStatus) {
  switch (poStatus.trim()) {
    case 'Pending GM Approval':
      return (
        label: 'Sent to GM',
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
  const GmPill({super.key, required this.poStatus});

  @override
  Widget build(BuildContext context) {
    final s = gmStatusOf(poStatus);
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

/// The notice at the top of the order page.
class GmBanner extends StatelessWidget {
  final String poStatus;
  const GmBanner({super.key, required this.poStatus});

  @override
  Widget build(BuildContext context) {
    final s = gmStatusOf(poStatus);
    if (s == null) return const SizedBox.shrink();
    final text = poStatus.trim() == 'Pending GM Approval'
        ? 'Over credit limit. Your manager sent this order to the GM.'
        : 'The GM approved it. Waiting for your manager to send it to SAP.';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.color.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Icon(s.icon, color: s.color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.label,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: s.color, fontSize: 15)),
            const SizedBox(height: 2),
            Text(text, style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

/// Chat-style ticks for an order waiting on the manager or the GM:
/// one grey tick when sent, two blue ticks once a manager has opened it,
/// "Sent to GM" once escalated. Null for every other status.
Widget? approvalTicks(String poStatus, dynamic managerSeenOn) {
  final po = poStatus.trim();
  final seen = '${managerSeenOn ?? ''}'.trim();
  const waiting = {
    'Pending Approval',
    'PO Uploaded - Pending Approval',
    'Pending Rate Approval',
  };
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
    return row(Icons.forward_to_inbox_rounded, const Color(0xFF6A1B9A), 'Sent to GM');
  }
  return null;
}
