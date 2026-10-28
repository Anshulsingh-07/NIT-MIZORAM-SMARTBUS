import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../utils/mp.dart';
import '../models/route_model.dart';

enum TravelMode { driving, walking, cycling, transit }

class RoutingService {
  /// Get a route between [origin] and [destination].
  /// Chooses provider based on available tokens (Google first, then Mapbox).
  static Future<RouteModel?> getRoute(
    LatLng origin,
    LatLng destination, {
    TravelMode mode = TravelMode.driving,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // Use a simple key for caching/dedupe
    final key = _cacheKey(origin, destination, mode);
    // Return cached result if fresh
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.timestamp).inSeconds <
            _cacheTtlSeconds) {
      return cached.model;
    }

    // If a request is already in-flight for the same key, return the same future
    if (_inflight.containsKey(key)) return _inflight[key]!.future;

    final completer = Completer<RouteModel?>();
    _inflight[key] = _InFlightRequest(completer.future);

    final googleKey = MP.googleMapsApiKey.trim();
    final mapboxToken = MP.mapboxToken.trim();

    RouteModel? result;
    try {
      if (googleKey.isNotEmpty) {
        result = await _getGoogleRoute(
          origin,
          destination,
          mode,
          googleKey,
          timeout,
        );
      }
      if ((result == null || result.primary == null) &&
          mapboxToken.isNotEmpty) {
        result = await _getMapboxRoute(
          origin,
          destination,
          mode,
          mapboxToken,
          timeout,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('RoutingService.getRoute error: $e');
      result = null;
    }

    // cache and complete
    if (result != null) {
      // insert into cache and maintain simple LRU order
      _cache[key] = _CachedRoute(model: result, timestamp: DateTime.now());
      _cacheOrder.remove(key);
      _cacheOrder.add(key);
      if (_cacheOrder.length > _cacheMaxEntries) {
        final oldest = _cacheOrder.removeAt(0);
        _cache.remove(oldest);
      }
    }
    completer.complete(result);
    _inflight.remove(key);
    return result;
  }

  static String _cacheKey(LatLng a, LatLng b, TravelMode mode) =>
      '${a.latitude.toStringAsFixed(4)},${a.longitude.toStringAsFixed(4)}|${b.latitude.toStringAsFixed(4)},${b.longitude.toStringAsFixed(4)}|${mode.toString()}';

  static final Map<String, _CachedRoute> _cache = {};
  static final Map<String, _InFlightRequest> _inflight = {};
  // LRU helpers to keep cache bounded
  static final List<String> _cacheOrder = [];
  static const int _cacheMaxEntries = 50;
  static const int _cacheTtlSeconds = 60;

  static String _modeName(TravelMode mode) {
    switch (mode) {
      case TravelMode.walking:
        return 'walking';
      case TravelMode.cycling:
        return 'bicycling';
      case TravelMode.transit:
        return 'transit';
      case TravelMode.driving:
        return 'driving';
    }
  }

  static Future<RouteModel?> _getGoogleRoute(
    LatLng origin,
    LatLng destination,
    TravelMode mode,
    String apiKey,
    Duration timeout,
  ) async {
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${destination.latitude},${destination.longitude}'
      '&mode=${_modeName(mode)}'
      '&alternatives=true'
      '&key=$apiKey',
    );

    try {
      final resp = await http.get(uri).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (decoded == null) return null;
      final routes = decoded['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return null;

      final options = <RouteOption>[];
      for (final r in routes) {
        final legs = r['legs'] as List<dynamic>? ?? [];
        int duration = 0;
        int distance = 0;
        if (legs.isNotEmpty) {
          duration = legs.fold(
            0,
            (p, e) => p + (e['duration']?['value'] as int? ?? 0),
          );
          distance = legs.fold(
            0,
            (p, e) => p + (e['distance']?['value'] as int? ?? 0),
          );
        }
        final overview = r['overview_polyline'] as Map<String, dynamic>?;
        final points = overview != null && overview['points'] is String
            ? _decodePolyline(overview['points'] as String)
            : <LatLng>[];
        options.add(
          RouteOption(
            provider: 'google',
            summary: r['summary']?.toString() ?? '',
            geometry: points,
            durationSeconds: duration,
            distanceMeters: distance,
          ),
        );
      }

      return RouteModel(options: options);
    } catch (e) {
      if (kDebugMode) debugPrint('Google routing failed: $e');
      return null;
    }
  }

  static Future<RouteModel?> _getMapboxRoute(
    LatLng origin,
    LatLng destination,
    TravelMode mode,
    String token,
    Duration timeout,
  ) async {
    // Map travel modes to Mapbox profiles
    final profile = switch (mode) {
      TravelMode.walking => 'walking',
      TravelMode.cycling => 'cycling',
      TravelMode.transit => 'driving',
      _ => 'driving',
    };
    final coords =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
    final uri = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/$profile/$coords'
      '?geometries=polyline&overview=full&alternatives=true&access_token=$token',
    );

    try {
      final resp = await http.get(uri).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (decoded == null) return null;
      final routes = decoded['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return null;

      final options = <RouteOption>[];
      for (final r in routes) {
        final duration = (r['duration'] as num?)?.toInt() ?? 0;
        final distance = (r['distance'] as num?)?.toInt() ?? 0;
        final geometry = r['geometry'] as String? ?? '';
        final points = geometry.isNotEmpty
            ? _decodePolyline(geometry)
            : <LatLng>[];
        options.add(
          RouteOption(
            provider: 'mapbox',
            summary: '',
            geometry: points,
            durationSeconds: duration,
            distanceMeters: distance,
          ),
        );
      }

      return RouteModel(options: options);
    } catch (e) {
      if (kDebugMode) debugPrint('Mapbox routing failed: $e');
      return null;
    }
  }

  // Polyline decoder (Google / Mapbox polyline precision=5)
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

class _CachedRoute {
  final RouteModel model;
  final DateTime timestamp;
  _CachedRoute({required this.model, required this.timestamp});
}

class _InFlightRequest {
  final Future<RouteModel?> future;
  _InFlightRequest(this.future);
}
