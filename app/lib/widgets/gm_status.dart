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
