import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteOption {
  final String provider;
  final String summary;
  final List<LatLng> geometry;
  final int durationSeconds;
  final int distanceMeters;

  RouteOption({
    required this.provider,
    required this.summary,
    required this.geometry,
    required this.durationSeconds,
    required this.distanceMeters,
  });
}

class RouteModel {
  final List<RouteOption> options;

  RouteModel({required this.options});

  RouteOption? get primary => options.isNotEmpty ? options.first : null;
}
