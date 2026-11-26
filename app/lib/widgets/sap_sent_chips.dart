import 'package:flutter/material.dart';
import 'package:manna_field_sales/core/sap_sent.dart';

/// What a Sales Order says about SAP, on every order list and order page:
/// Sent to SAP (or Waiting for SAP), who approved it, and SAP's numbers.
/// The rule is `core/sap_sent.dart`; the dashboard draws the same line.
///
/// Draws nothing when there is nothing to say, so a caller need not check.
class SapSentChips extends StatelessWidget {
  final Map<String, dynamic> order;

  /// False where the same screen already shows the numbers in its own line.
  final bool showNumbers;
  const SapSentChips({super.key, required this.order, this.showNumbers = true});

  @override
  Widget build(BuildContext context) {
    final s = SapSent.fromOrder(order);
    if (s.label.isEmpty &&
        s.approvedBy.isEmpty &&
        s.status.isEmpty &&
        (!showNumbers || s.numbers.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (s.label.isNotEmpty)
            _chip(
              s.label,
              s.sent ? const Color(0xFF2E7D32) : const Color(0xFFE65100),
              s.sent ? Icons.cloud_done_rounded : Icons.schedule_rounded,
            ),
          if (s.approvedBy.isNotEmpty)
            _chip(
              s.approvedBy,
              s.approvedBy == kGmApproved
                  ? const Color(0xFF6A1B9A)
                  : const Color(0xFF1565C0),
              Icons.verified_rounded,
            ),
          // Where the order is in SAP (26 Nov 2026): B1iF's word, or
          // Hi-Tech's document state before B1iF has reported.
          if (s.status.isNotEmpty)
            _chip('SAP status: ${s.status}', _statusColour(s.status),
                Icons.inventory_2_outlined),
          if (showNumbers && s.numbers.isNotEmpty)
            Text(s.numbers,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  static Color _statusColour(String status) => switch (status) {
        'Dispatched' => const Color(0xFF2E7D32),
        'Cancelled' => const Color(0xFFC62828),
        'Picked' || 'Partially Picked' || 'Partially Dispatched' =>
          const Color(0xFF00838F),
        _ => const Color(0xFF455A64),
      };

  Widget _chip(String label, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}

/// An order page's title: both SAP numbers once SAP has the order, else
/// [fallback]. Shrinks to fit rather than wrapping out of the app bar.
class SapOrderTitle extends StatelessWidget {
  final Map order;
  final String fallback;
  const SapOrderTitle({super.key, required this.order, this.fallback = 'Order'});

  @override
  Widget build(BuildContext context) {
    final n = sapNumbersOf(order);
    if (n.isEmpty) return Text(fallback);
    return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(n));
  }
}
