// The handful of pieces every manager screen draws the same way.
//
// The manager screens grew one at a time and each hand-rolled its own status
// chip, empty state and money format — three money formats across five
// screens by October 2026. These are the one copy.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/services/api.dart';

const Color kBrand = Color(0xFFF46A21);
const Color kInk = Color(0xFF3F3F3F);
const Color kMuted = Color(0xFF6B7280);
const Color kLine = Color(0xFFECECEC);

enum Tone { good, warn, bad, info, neutral }

Color toneColor(Tone t) => switch (t) {
      Tone.good => const Color(0xFF1B7F3B),
      Tone.warn => const Color(0xFFB45309),
      Tone.bad => const Color(0xFFB3261E),
      Tone.info => const Color(0xFF2563EB),
      Tone.neutral => kMuted,
    };

/// A short status, in capitals, on a tint of its colour.
class StatusPill extends StatelessWidget {
  final String label;
  final Tone tone;
  const StatusPill(this.label, {super.key, this.tone = Tone.neutral});

  @override
  Widget build(BuildContext context) {
    final c = toneColor(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20)),
      child: Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w700,
              color: c)),
    );
  }
}

/// A heading above a group of cards.
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                    color: kMuted)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Nothing to show, said once and quietly.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: Colors.black26),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kMuted)),
          ]),
        ),
      );
}

/// A failed load, with a way to try again.
class ErrorState extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const ErrorState({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40, color: Colors.black26),
            const SizedBox(height: 10),
            Text(humanError(error),
                textAlign: TextAlign.center,
                style: const TextStyle(color: kMuted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ]),
        ),
      );
}

/// A white rounded block, the base of every card on these screens.
class Panel extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const Panel(
      {super.key,
      required this.child,
      this.onTap,
      this.padding = const EdgeInsets.all(14),
      this.color});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        color: color,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
}

double numOf(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

/// Frappe reads an unset field back as null, '' or the string 'null'.
String textOf(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// Money in the team's currency: ₹ with Indian grouping, or AED with
/// thousands. Whole units — nobody approves an order on its paise.
String money(num v) {
  final aed = Api.teamCurrency == 'AED';
  final neg = v < 0;
  var digits = v.abs().round().toString();
  if (digits.length > 3) {
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    final size = aed ? 3 : 2;
    while (rest.length > size) {
      groups.insert(0, rest.substring(rest.length - size));
      rest = rest.substring(0, rest.length - size);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    digits = '${groups.join(',')},$last3';
  }
  return '${neg ? '-' : ''}${aed ? 'AED ' : '₹'}$digits';
}

/// A large amount, shortened for a tile: ₹4.2L, ₹1.3Cr, AED 85K.
String moneyShort(num v) {
  final aed = Api.teamCurrency == 'AED';
  final a = v.abs();
  String n;
  if (aed) {
    n = a >= 1e6
        ? '${(a / 1e6).toStringAsFixed(1)}M'
        : a >= 1e3
            ? '${(a / 1e3).toStringAsFixed(0)}K'
            : a.round().toString();
  } else {
    n = a >= 1e7
        ? '${(a / 1e7).toStringAsFixed(1)}Cr'
        : a >= 1e5
            ? '${(a / 1e5).toStringAsFixed(1)}L'
            : a >= 1e3
                ? '${(a / 1e3).toStringAsFixed(0)}K'
                : a.round().toString();
  }
  return '${v < 0 ? '-' : ''}${aed ? 'AED ' : '₹'}$n';
}

/// "12 Oct" from an ISO date.
String shortDate(dynamic iso) {
  final d = DateTime.tryParse(textOf(iso).replaceFirst(' ', 'T'));
  if (d == null) return textOf(iso);
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]}';
}

/// Whole days since an ISO timestamp, never negative.
int daysSince(dynamic iso, DateTime now) {
  final d = DateTime.tryParse(textOf(iso).replaceFirst(' ', 'T'));
  if (d == null) return 0;
  final n = now.difference(d).inDays;
  return n < 0 ? 0 : n;
}

/// Asks before something that cannot be taken back. True to go ahead.
Future<bool> confirmAction(BuildContext context,
    {required String title,
    String? body,
    required String action,
    bool destructive = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: toneColor(Tone.bad))
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// Approve and reject, side by side, the same on every approval card.
class DecisionButtons extends StatelessWidget {
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final String approveLabel;
  final String rejectLabel;
  const DecisionButtons(
      {super.key,
      required this.onApprove,
      required this.onReject,
      this.approveLabel = 'Approve',
      this.rejectLabel = 'Reject'});

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: toneColor(Tone.bad),
                side: BorderSide(color: toneColor(Tone.bad).withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            onPressed: onReject,
            child: Text(rejectLabel),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: onApprove,
            child: Text(approveLabel),
          ),
        ),
      ]);
}
