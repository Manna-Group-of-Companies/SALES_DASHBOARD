import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';


const String kMapTilerKey = '';
String mapTileUrl() => kMapTilerKey.isEmpty
    ? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
    : 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key=$kMapTilerKey';

// A point the map can actually project. Web Mercator blows up towards the
// poles, so anything past ~85° (or a NaN/infinite value from bad GPS data)
// would produce infinite pixel bounds and crash the tile layer.
bool isMappableLatLng(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat.abs() <= 85.05 &&
    lng.abs() <= 180 &&
    !(lat == 0 && lng == 0);

// Center + a safe zoom for a set of points. Used instead of initialCameraFit,
// which can leave map tiles blank until the first user interaction.
({LatLng center, double zoom}) mapCenterZoom(List<LatLng> all) {
  final pts = all
      .where((p) => isMappableLatLng(p.latitude, p.longitude))
      .toList();
  if (pts.isEmpty) return (center: const LatLng(10.2, 76.3), zoom: 7.2);
  double minLa = pts.first.latitude, maxLa = minLa;
  double minLo = pts.first.longitude, maxLo = minLo;
  for (final p in pts) {
    if (p.latitude < minLa) minLa = p.latitude;
    if (p.latitude > maxLa) maxLa = p.latitude;
    if (p.longitude < minLo) minLo = p.longitude;
    if (p.longitude > maxLo) maxLo = p.longitude;
  }
  final center = LatLng((minLa + maxLa) / 2, (minLo + maxLo) / 2);
  final span = (maxLa - minLa) > (maxLo - minLo)
      ? (maxLa - minLa)
      : (maxLo - minLo);
  double zoom;
  if (span < 0.004) {
    zoom = 15;
  } else if (span < 0.012) {
    zoom = 14;
  } else if (span < 0.03) {
    zoom = 13;
  } else if (span < 0.07) {
    zoom = 12;
  } else if (span < 0.15) {
    zoom = 11;
  } else if (span < 0.3) {
    zoom = 10;
  } else if (span < 0.6) {
    zoom = 9;
  } else if (span < 1.2) {
    zoom = 8;
  } else {
    zoom = 7;
  }
  return (center: center, zoom: zoom);
}

Future<void> navigateTo(double lat, double lng) async {
  final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

