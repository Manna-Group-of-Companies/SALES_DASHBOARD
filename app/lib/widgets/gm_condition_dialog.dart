// What the GM approves an over-limit order on.
//
// One dialog for both places the GM approves on the phone — the GM queue and
// the order review — so the rule cannot differ between them. Until
// 24 September 2026 only the queue could approve: the review offered the GM
// "Send to GM" on an order already escalated to them.
//
// With the rep's commitment on the order the condition is required and starts
// as the rep's own words (credit_commitment.json). Without one it is optional,
// as it always was. Cancelling is its own answer: the old dialog read a tap
// outside it as "approve, no condition".

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/credit_commitment.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/core/week.dart';

/// The GM's answer. Null from [askGmCondition] means they backed out.
class GmApproval {
  /// Empty when approving with no condition, which only an order without a
  /// commitment allows.
  final String condition;
  final String dueIso;
  const GmApproval(this.condition, this.dueIso);
}

Future<GmApproval?> askGmCondition(
  BuildContext context, {
  required String party,
  required String rep,
  required dynamic commitment,
  required dynamic commitmentDue,
}) {
  final needed = conditionRequiredOnApproval(commitment);
  final ctrl =
      TextEditingController(text: needed ? '$commitment'.trim() : '');
  var due = DateTime.parse(defaultConditionDue(commitmentDue, serverNow()));
  String? problem;

  return showDialog<GmApproval>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(needed
            ? 'Approve on the rep’s commitment'
            : 'Approve with a condition?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                needed
                    ? '$rep committed to this for $party. Approving makes it '
                        'their condition until you close it, and sends the '
                        'order back to the sales manager to push to SAP. You '
                        'may change the words, not drop them.'
                    : 'This order is over the credit limit for $party and came '
                        'without a commitment. Anything typed here becomes a '
                        'condition owned by $rep until you close it. Approving '
                        'sends the order back to the sales manager to push to '
                        'SAP.',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: !needed,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Condition',
                hintText:
                    'e.g. clear the 60-day outstanding before the next order',
                border: const OutlineInputBorder(),
                errorText: problem,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (problem != null) setLocal(() => problem = null);
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Due by', style: TextStyle(fontSize: 13)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: due.isBefore(now) ? now : due,
                    firstDate: now,
                    lastDate: now.add(const Duration(days: 365)),
                  );
                  if (picked != null) setLocal(() => due = picked);
                },
                child: Text(isoDate(due)),
              ),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          // Approving without one is a normal outcome — but only where there
          // was no commitment to begin with.
          if (!needed)
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, GmApproval('', isoDate(due))),
                child: const Text('Approve, no condition')),
          FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              final p = needed
                  ? approvalConditionProblem(commitment, text)
                  : (text.isEmpty ? 'Type the condition, or approve with none.' : null);
              if (p != null) {
                setLocal(() => problem = p);
                return;
              }
              Navigator.pop(ctx, GmApproval(text, isoDate(due)));
            },
            // Not "send to SAP": the GM approves the credit and the sales
            // manager pushes (credit_commitment.json).
            child: const Text('Approve'),
          ),
        ],
      ),
    ),
  );
}
