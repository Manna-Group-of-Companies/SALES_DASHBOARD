// The home screen's tiles at phone and tablet widths. Written after 1.1.18
// (18 Nov 2026): on a 360-dp phone "Payment Commitments" wrapped flush left
// against the tile's border, its icon off-centre above it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/responsive.dart';
import 'package:manna_field_sales/widgets/home_tile.dart';

const _labels = [
  'Credit Periods',
  'Payment Commitments',
  'My Conditions',
  'Collections',
  'Item Request Approvals',
  'Unsent Punches (12)',
];

Future<void> _pumpGrid(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 1600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Builder(
          builder: (context) => GridView.count(
            crossAxisCount: gridColumns(MediaQuery.of(context).size.width - 32),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final l in _labels) HomeTile(label: l, icon: Icons.add_card, onTap: () {}),
            ],
          ),
        ),
      ),
    ),
  ));
}

void main() {
  for (final width in [360.0, 412.0, 800.0]) {
    testWidgets('every label fits its tile, centred, at $width dp', (tester) async {
      await _pumpGrid(tester, width);
      expect(tester.takeException(), isNull, reason: 'no overflow at $width dp');
      for (final l in _labels) {
        final text = tester.widget<Text>(find.text(l));
        expect(text.textAlign, TextAlign.center, reason: l);
        expect(text.maxLines, 2, reason: l);
        final tile = tester.getRect(find.ancestor(of: find.text(l), matching: find.byType(Card)));
        final label = tester.getRect(find.text(l));
        // Inside the card, with room on both sides, and centred in it.
        expect(label.left, greaterThan(tile.left + 4), reason: l);
        expect(label.right, lessThan(tile.right - 4), reason: l);
        expect((label.center.dx - tile.center.dx).abs(), lessThan(1), reason: l);
      }
    });
  }

  testWidgets('the icon sits centred above a wrapped label', (tester) async {
    await _pumpGrid(tester, 360);
    final tile = find.ancestor(of: find.text('Payment Commitments'), matching: find.byType(Card));
    final icon = find.descendant(of: tile, matching: find.byType(Icon));
    expect((tester.getCenter(icon).dx - tester.getCenter(tile).dx).abs(), lessThan(1));
  });
}
