import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class LocationService {
  /// Request permission and get current position once.
  static Future<Position?> requestPermissionAndGetLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;

    try {
      final pos = await Geolocator.getCurrentPosition();
      return pos;
    } catch (_) {
      return null;
    }
  }

  /// Returns a stream of position updates.
  static Stream<Position> getPositionStream({int intervalSeconds = 5}) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5),
    );
  }

  /// Convert Geolocator [Position] to LatLng
  static LatLng toLatLng(Position p) => LatLng(p.latitude, p.longitude);
}
