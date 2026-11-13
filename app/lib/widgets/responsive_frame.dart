import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/responsive.dart';

/// Holds the whole app to [kContentMaxWidth], centred, on a wider screen.
///
/// Placed once, in MaterialApp.builder (app.dart), so every route, dialog and
/// bottom sheet is inside it. The MediaQuery below it reports the column's
/// width, not the screen's, so a screen that sizes itself from
/// MediaQuery.size lays out for the width it really has. On a phone, and on a
/// portrait tablet, it changes nothing.
class ResponsiveFrame extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveFrame({super.key, required this.child, this.maxWidth = kContentMaxWidth});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.size.width <= maxWidth) return child;
    return ColoredBox(
      // The page colour, so the margins read as background, not as a gap.
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: SizedBox(
          width: maxWidth,
          child: MediaQuery(
            data: mq.copyWith(size: Size(maxWidth, mq.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}
