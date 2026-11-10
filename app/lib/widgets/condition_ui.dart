// The look of the GM's credit conditions on the phone (10 Nov 2026): the
// colours, the status badge, the due / set-by chips and the activity
// timeline. Shared by My Conditions and the answer dialog so the two read as
// one design. Orange and white, the app's own theme; green only for a closed
// condition, red only for an overdue one.

import 'package:flutter/material.dart';

class CondColors {
  static const orange = Color(0xFFFF6B1A);
  static const orange2 = Color(0xFFFF8A3D);
  static const background = Color(0xFFFFFFFF);
  static const lightOrange = Color(0xFFFFF0E6);
  static const card = Color(0xFFFFFFFF);
  static const text = Color(0xFF252525);
  static const muted = Color(0xFF777777);
  static const border = Color(0xFFF1E4DC);
  static const green = Color(0xFF16A34A);
  static const red = Color(0xFFDC2626);
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `2026-11-12` or `2026-11-12 09:36:00` as `12 Nov 2026`; '' when unset.
String condDate(String iso) {
  final s = iso.trim();
  if (s.length < 10 || s == 'null') return '';
  final d = DateTime.tryParse(s.substring(0, 10));
  if (d == null) return s;
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// A condition's state, as the rep reads it.
enum CondBadge { open, awaiting, closed, overdue }

class CondStatusBadge extends StatelessWidget {
  final CondBadge kind;
  const CondStatusBadge(this.kind, {super.key});

  @override
  Widget build(BuildContext context) {
    final (String label, IconData icon, Color fg, Color bg) = switch (kind) {
      CondBadge.overdue => ('Overdue', Icons.error_rounded, CondColors.red, const Color(0xFFFDECEC)),
      CondBadge.closed => ('Closed', Icons.check_circle_rounded, CondColors.green, const Color(0xFFE8F6EE)),
      CondBadge.awaiting => ('Awaiting review', Icons.hourglass_top_rounded, CondColors.orange, CondColors.lightOrange),
      CondBadge.open => ('Open', Icons.radio_button_checked_rounded, Colors.white, CondColors.orange),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg, letterSpacing: 0.1)),
      ]),
    );
  }
}

/// A small labelled fact under a condition: the deadline, who set it.
class CondMetaChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool alert;
  const CondMetaChip({super.key, required this.icon, required this.text, this.alert = false});

  @override
  Widget build(BuildContext context) {
    final fg = alert ? CondColors.red : CondColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: alert ? const Color(0xFFFDECEC) : const Color(0xFFFAF6F3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                fontSize: 12, color: alert ? CondColors.red : CondColors.text, fontWeight: alert ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }
}

/// One step in a condition's history.
class CondEvent {
  final IconData icon;
  final Color color;
  final String who;
  final String role;
  final String when;
  final String text;

  /// The rep's own words, set apart so they are found at a glance.
  final bool mine;

  const CondEvent({
    required this.icon,
    required this.color,
    required this.who,
    this.role = '',
    this.when = '',
    this.text = '',
    this.mine = false,
  });
}

/// The history of a condition, oldest first: icons on a connecting line.
class CondTimeline extends StatelessWidget {
  final List<CondEvent> events;
  const CondTimeline({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < events.length; i++) _row(events[i], last: i == events.length - 1),
    ]);
  }

  Widget _row(CondEvent e, {required bool last}) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 32,
          child: Column(children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: e.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: e.color.withValues(alpha: 0.35)),
              ),
              child: Icon(e.icon, size: 15, color: e.color),
            ),
            if (!last)
              Expanded(
                child: Container(
                  width: 2,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  decoration: BoxDecoration(color: CondColors.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 14, top: 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                Text(e.who,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CondColors.text)),
                if (e.role.isNotEmpty)
                  Text(e.role, style: const TextStyle(fontSize: 11.5, color: CondColors.muted)),
                if (e.when.isNotEmpty)
                  Text('· ${e.when}', style: const TextStyle(fontSize: 11.5, color: CondColors.muted)),
              ]),
              if (e.text.isNotEmpty) ...[
                const SizedBox(height: 5),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
                  decoration: BoxDecoration(
                    color: e.mine ? CondColors.lightOrange : const Color(0xFFFAF8F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: e.mine ? const Color(0xFFFFD2B5) : CondColors.border),
                  ),
                  child: Text(e.text,
                      style: const TextStyle(fontSize: 13, height: 1.4, color: CondColors.text)),
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}
