// Where a customer, lead or site sits, as the screens should read it.
//
// Three screens each worked out a party's coordinates on their own, and two
// of them did it wrong: the maps took `(v is num) ? v : 0.0`, so a coordinate
// that came back as text was silently (0, 0) — a pin in the Atlantic the map
// then discarded. The customer list beside it parsed the text and showed the
// figures; the map showed nothing. And none of the three looked at the
// verified pair, which for a legacy import can be the only pair there is.
//
// One reading, used everywhere a pin is drawn or quoted.

import 'package:manna_field_sales/core/proximity.dart';

/// A coordinate as the backend sends it.
///
/// Floats arrive as numbers, legacy Data fields as text, and an unset field
/// as null, '' or the string 'null' (app/CLAUDE.md §4). Every one of those
/// must read as the number it is or as nothing. Nothing reads as 0, which
/// [isRealCoordinate] already discards — so a caller cannot mistake it for a
/// place.
double coordOf(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}'.trim()) ?? 0;
}

/// One position for a place.
class PartyLatLng {
  final double lat;
  final double lng;
  const PartyLatLng(this.lat, this.lng);
}

/// Where [row] sits, or null when it has no usable position.
///
/// The verified pair wins. It is what every punch-in is measured against
/// (`Api.registeredPlacesFor` reads it the same way), so the pin a rep sees
/// on the map is the pin they will be judged by. The captured pair is the
/// fallback, not an afterthought: a rep's own capture waits on a manager and
/// has no verified pair yet, and it must still show on the map rather than
/// read as "no location".
///
/// [prefix] is `custom_` on Customer and Lead and empty on Customer Site —
/// the field-naming trap in app/CLAUDE.md §4.
PartyLatLng? partyLatLng(Map<String, dynamic> row,
    {String prefix = 'custom_'}) {
  final vLat = coordOf(row['${prefix}verified_latitude']);
  final vLng = coordOf(row['${prefix}verified_longitude']);
  if (isRealCoordinate(vLat, vLng)) return PartyLatLng(vLat, vLng);
  final cLat = coordOf(row['${prefix}latitude']);
  final cLng = coordOf(row['${prefix}longitude']);
  if (isRealCoordinate(cLat, cLng)) return PartyLatLng(cLat, cLng);
  return null;
}
