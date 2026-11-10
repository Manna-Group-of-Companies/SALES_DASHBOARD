// The rep's answer to a GM condition (redesigned 10 Nov 2026): a rounded
// dialog that rises above the keyboard. Used by My Conditions and by the
// customer page's credit conditions; both take back the text, or null when the
// rep cancels, exactly as before.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/widgets/condition_ui.dart';

/// Returns the rep's answer, trimmed, or null when they close it unsent.
Future<String?> showConditionAnswerSheet(
  BuildContext context, {
  required String condition,
  String initial = '',
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => _AnswerDialog(condition: condition, initial: initial),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

class _AnswerDialog extends StatefulWidget {
  final String condition;
  final String initial;
  const _AnswerDialog({required this.condition, required this.initial});

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ctrl.text.trim().isNotEmpty;
    // Dialog pads itself by the keyboard's height, so it sits above it; the
    // scroll view keeps a short screen with the keyboard up from overflowing.
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(color: CondColors.lightOrange, shape: BoxShape.circle),
                  child: const Icon(Icons.info_rounded, color: CondColors.orange, size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('What have you done about it?',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800, color: CondColors.text, height: 1.25)),
                ),
              ]),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
                decoration: BoxDecoration(
                  color: CondColors.lightOrange,
                  borderRadius: BorderRadius.circular(14),
                  border: const Border(left: BorderSide(color: CondColors.orange, width: 3.5)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('CONDITION',
                      style: TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w800, color: CondColors.orange, letterSpacing: 0.8)),
                  const SizedBox(height: 4),
                  Text(widget.condition,
                      style: const TextStyle(fontSize: 14, height: 1.45, color: CondColors.text)),
                ]),
              ),
              const SizedBox(height: 18),
              const Text('Your answer',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CondColors.text)),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 14.5, height: 1.45, color: CondColors.text),
                decoration: InputDecoration(
                  hintText: 'Write what you did',
                  hintStyle: const TextStyle(color: Color(0xFFAAAAAA)),
                  filled: true,
                  // The answer stands out once there is one.
                  fillColor: ready ? const Color(0xFFFFF8F3) : const Color(0xFFFAFAFA),
                  contentPadding: const EdgeInsets.all(14),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: ready ? const Color(0xFFFFC7A3) : CondColors.border, width: 1.2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: CondColors.orange, width: 1.6),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Row(children: [
                Icon(Icons.gavel_rounded, size: 15, color: CondColors.muted),
                SizedBox(width: 6),
                Expanded(
                  child: Text('The GM decides on this.',
                      style: TextStyle(fontSize: 12.5, color: CondColors.muted)),
                ),
              ]),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: CondColors.text,
                      side: const BorderSide(color: CondColors.border, width: 1.2),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: CondColors.orange,
                      disabledBackgroundColor: const Color(0xFFFFD2B5),
                      disabledForegroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: ready ? () => Navigator.pop(context, _ctrl.text.trim()) : null,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Send for review',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
