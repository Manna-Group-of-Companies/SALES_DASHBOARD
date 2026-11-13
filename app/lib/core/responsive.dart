// Tablets and wide screens (13 Nov 2026, the user: "the app in responsive").
//
// Every screen was laid out for a phone and stretched edge to edge on a
// tablet: a 1280-wide row of text, a home grid of two tiles each the size of a
// paperback. Rather than rework fifty screens, the app keeps its phone layout
// and caps how wide it grows: on a screen wider than [kContentMaxWidth] the
// whole app sits in a centred column that wide (widgets/responsive_frame.dart),
// and the few grids choose their column count from the width they are given.

/// The widest the app's content grows, in logical pixels. A portrait tablet
/// (about 800) uses its full width; a landscape tablet gets a centred column.
const double kContentMaxWidth = 840;

/// How many columns a grid of tiles at least [minTile] wide fits into [width],
/// never fewer than [min] (a phone keeps its two) nor more than [max].
int gridColumns(double width, {double minTile = 190, int min = 2, int max = 4}) {
  if (!width.isFinite || width <= 0) return min;
  return (width / minTile).floor().clamp(min, max);
}
