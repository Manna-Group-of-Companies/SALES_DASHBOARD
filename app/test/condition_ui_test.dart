import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/widgets/condition_answer_sheet.dart';
import 'package:manna_field_sales/widgets/condition_ui.dart';

const _condition =
    'Clear the sixty-day outstanding of Rs 36,561 by the fifteenth and collect a cheque before the next delivery.';

/// A phone of [size], optionally with the keyboard up.
Future<void> _phone(WidgetTester t, Size size, {double keyboard = 0}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(t.view.reset);
}

Future<String?> _open(WidgetTester t, {String initial = ''}) async {
  String? result = 'unset';
  await t.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async =>
                result = await showConditionAnswerSheet(ctx, condition: _condition, initial: initial),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return result;
}

void main() {
  for (final (label, size, keyboard) in [
    ('a small phone', const Size(320, 568), 0.0),
    ('a small phone with the keyboard up', const Size(320, 568), 260.0),
    ('a large phone with the keyboard up', const Size(412, 915), 330.0),
  ]) {
    testWidgets('the answer dialog fits $label', (t) async {
      await _phone(t, size, keyboard: keyboard);
      await _open(t);
      expect(t.takeException(), isNull);
      expect(find.text('What have you done about it?'), findsOneWidget);
      expect(find.text('The GM decides on this.'), findsOneWidget);
      expect(find.text('Send for review'), findsOneWidget);
    });
  }

  testWidgets('Send for review waits for an answer and returns it trimmed', (t) async {
    await _phone(t, const Size(412, 915));
    String? sent = 'unset';
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async => sent = await showConditionAnswerSheet(ctx, condition: _condition),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    final send = find.widgetWithText(FilledButton, 'Send for review');
    expect(t.widget<FilledButton>(send).onPressed, isNull);

    await t.enterText(find.byType(TextField), '  Cheque collected on Friday  ');
    await t.pump();
    await t.tap(send);
    await t.pumpAndSettle();
    expect(sent, 'Cheque collected on Friday');
  });

  testWidgets('Cancel sends nothing', (t) async {
    await _phone(t, const Size(412, 915));
    String? sent = 'unset';
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                sent = await showConditionAnswerSheet(ctx, condition: _condition, initial: 'Old answer'),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Old answer'), findsOneWidget, reason: 'the answer already given is there to change');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(sent, isNull);
  });

  testWidgets('the timeline and badges fit a narrow phone', (t) async {
    await _phone(t, const Size(320, 568));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            const Wrap(children: [
              CondStatusBadge(CondBadge.open),
              CondStatusBadge(CondBadge.awaiting),
              CondStatusBadge(CondBadge.closed),
              CondStatusBadge(CondBadge.overdue),
            ]),
            const CondMetaChip(icon: Icons.event_rounded, text: 'Due 12 Nov 2026', alert: true),
            CondTimeline(events: [
              const CondEvent(
                  icon: Icons.flag_rounded,
                  color: CondColors.orange,
                  who: 'Rajiv Chandrasekharan Pillai',
                  role: 'set this condition',
                  when: '7 Nov 2026',
                  text: 'Due by 12 Nov 2026'),
              CondEvent(
                  icon: Icons.person_rounded,
                  color: CondColors.orange,
                  who: 'You',
                  when: '8 Nov 2026',
                  text: _condition * 3,
                  mine: true),
            ]),
          ]),
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    expect(find.text('Awaiting review'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
  });

  test('dates read as people say them', () {
    expect(condDate('2026-11-12'), '12 Nov 2026');
    expect(condDate('2026-11-07 09:36:00.123'), '7 Nov 2026');
    expect(condDate(''), '');
    expect(condDate('null'), '');
  });
}
