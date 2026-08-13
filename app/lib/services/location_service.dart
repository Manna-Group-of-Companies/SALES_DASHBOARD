import 'dart:async';

import 'package:geolocator/geolocator.dart';


Future<Position> getCurrentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Location services are off. Turn on GPS.');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    throw Exception('Location permission denied.');
  }
  return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
}

