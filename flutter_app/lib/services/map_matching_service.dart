import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../utils/mp.dart';

class MapMatchingService {
  /// Use Mapbox Map Matching to snap a geometry to the road network.
  /// Returns a list of LatLng points or null on failure.
  static Future<List<LatLng>?> matchGeometry(List<LatLng> coords) async {
    if (coords.length < 2) return coords;
    final token = MP.mapboxToken.trim();
    if (token.isEmpty) return coords;

    final coordsStr = coords.map((c) => '${c.longitude},${c.latitude}').join(';');
    final uri = Uri.parse(
        'https://api.mapbox.com/matching/v5/mapbox/driving/$coordsStr?geometries=polyline&overview=full&access_token=$token');
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>?;
      final matchings = decoded?['matchings'] as List<dynamic>? ?? [];
      if (matchings.isEmpty) return null;
      // Take the first matching's geometry
      final geom = matchings.first['geometry'] as String?;
      if (geom == null || geom.isEmpty) return null;
      return _decodePolyline(geom);
    } catch (_) {
      return null;
    }
  }

  // Polyline decoder (precision 5)
  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int result = 0;
      int shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final deltaLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += deltaLat;

      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final deltaLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += deltaLng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }
}
