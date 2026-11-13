// Tablets (13 Nov 2026): the app keeps its phone layout and is held to a
// readable width on a wider screen; grids add columns as the width allows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/responsive.dart';
import 'package:manna_field_sales/widgets/responsive_frame.dart';

/// Lays a [ResponsiveFrame] out on a screen [width] wide and reports the
/// width its child was given and the width MediaQuery told it.
Future<(double, double)> _frameOn(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late double laidOut;
  late double reported;
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ResponsiveFrame(child: child!),
    home: LayoutBuilder(builder: (context, c) {
      laidOut = c.maxWidth;
      reported = MediaQuery.of(context).size.width;
      return const SizedBox.shrink();
    }),
  ));
  return (laidOut, reported);
}

void main() {
  group('the app on a wide screen', () {
    testWidgets('a phone keeps its full width', (tester) async {
      final (laid, told) = await _frameOn(tester, 400);
      expect(laid, 400);
      expect(told, 400);
    });

    testWidgets('a portrait tablet keeps its full width', (tester) async {
      final (laid, told) = await _frameOn(tester, 800);
      expect(laid, 800);
      expect(told, 800);
    });

    testWidgets('a landscape tablet holds the app to a readable column', (tester) async {
      final (laid, _) = await _frameOn(tester, 1280);
      expect(laid, kContentMaxWidth);
    });

    testWidgets('screens that size themselves from MediaQuery are told the column, not the screen',
        (tester) async {
      final (_, told) = await _frameOn(tester, 1280);
      expect(told, kContentMaxWidth);
    });
  });

  group('grid columns', () {
    test('a phone keeps two tiles a row', () => expect(gridColumns(328), 2));
    test('a narrow phone never drops to one', () => expect(gridColumns(280), 2));
    test('a portrait tablet fits three or four', () => expect(gridColumns(768), 4));
    test('a small tablet fits three', () => expect(gridColumns(600), 3));
    test('never more than four, however wide', () => expect(gridColumns(5000), 4));
    test('an unknown width falls back to two', () => expect(gridColumns(double.infinity), 2));
  });
}
