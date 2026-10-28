import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Cached OpenStreetMap campus graph with a local Dijkstra route and OSRM fallback.
class CampusRoutingService {
  static const _cacheKey = 'campus_osm_roads_v1';
  static const _overpass = 'https://overpass-api.de/api/interpreter';

  Map<int, _Node>? _nodes;
  final Map<int, List<_Edge>> _edges = {};

  Future<List<LatLng>> route(
    LatLng from,
    LatLng to, {
    bool allowFallback = true,
  }) async {
    await _ensureGraph();
    final local = await compute(
      _findPath,
      _RouteInput(
        nodes: _nodes!.values
            .map((node) => [node.id, node.lat, node.lng])
            .toList(),
        edges: _edges.entries
            .expand((entry) => entry.value.map((edge) => [entry.key, edge.to]))
            .toList(),
        from: <num>[from.latitude, from.longitude],
        to: <num>[to.latitude, to.longitude],
      ),
    );
    if (local.isNotEmpty) return local.map((p) => LatLng(p[0], p[1])).toList();
    if (!allowFallback) return const <LatLng>[];

    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final routes =
            (jsonDecode(response.body) as Map<String, dynamic>)['routes']
                as List?;
        final coordinates =
            routes?.firstOrNull?['geometry']?['coordinates'] as List?;
        if (coordinates != null && coordinates.isNotEmpty) {
          return coordinates
              .map(
                (point) => LatLng(
                  (point[1] as num).toDouble(),
                  (point[0] as num).toDouble(),
                ),
              )
              .toList();
        }
      }
    } catch (_) {}
    return const <LatLng>[];
  }

  Future<void> _ensureGraph() async {
    if (_nodes != null) return;
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_cacheKey);
    if (raw == null) {
      try {
        final response = await http
            .post(
              Uri.parse(_overpass),
              body: {
                'data':
                    '[out:json][timeout:15];way["highway"](23.730,92.700,23.810,92.750);(._;>;);out body;',
              },
            )
            .timeout(const Duration(seconds: 18));
        if (response.statusCode == 200) {
          raw = response.body;
          await prefs.setString(_cacheKey, raw);
        }
      } catch (_) {}
    }
    _nodes = {};
    if (raw == null) return;
    try {
      final elements = (jsonDecode(raw)['elements'] as List)
          .cast<Map<String, dynamic>>();
      for (final item in elements.where((e) => e['type'] == 'node')) {
        _nodes![item['id'] as int] = _Node(
          item['id'] as int,
          (item['lat'] as num).toDouble(),
          (item['lon'] as num).toDouble(),
        );
      }
      for (final way in elements.where((e) => e['type'] == 'way')) {
        final ids = (way['nodes'] as List?)?.cast<int>() ?? [];
        final tags = way['tags'] as Map<String, dynamic>? ?? {};
        final reverse =
            tags['oneway'] == 'yes' ||
            tags['oneway'] == '1' ||
            tags['junction'] == 'roundabout';
        final reverseOnly = tags['oneway'] == '-1';
        for (var i = 0; i + 1 < ids.length; i++) {
          if (!_nodes!.containsKey(ids[i]) ||
              !_nodes!.containsKey(ids[i + 1])) {
            continue;
          }
          if (!reverseOnly) {
            _edges.putIfAbsent(ids[i], () => []).add(_Edge(ids[i + 1]));
          }
          if (!reverse) {
            _edges.putIfAbsent(ids[i + 1], () => []).add(_Edge(ids[i]));
          }
        }
      }
    } catch (_) {
      _nodes = {};
      _edges.clear();
    }
  }
}

class _Node {
  final int id;
  final double lat, lng;
  const _Node(this.id, this.lat, this.lng);
}

class _Edge {
  final int to;
  const _Edge(this.to);
}

class _QueueEntry {
  final double distance;
  final int node;
  const _QueueEntry(this.distance, this.node);
}

class _RouteInput {
  final List<List<num>> nodes, edges;
  final List<num> from, to;
  const _RouteInput({
    required this.nodes,
    required this.edges,
    required this.from,
    required this.to,
  });
}

List<List<double>> _findPath(_RouteInput input) {
  if (input.nodes.isEmpty) return [];
  final coords = <int, List<double>>{
    for (final n in input.nodes)
      n[0].toInt(): [n[1].toDouble(), n[2].toDouble()],
  };
  final graph = <int, List<int>>{};
  for (final edge in input.edges) {
    graph.putIfAbsent(edge[0].toInt(), () => []).add(edge[1].toInt());
  }
  int nearest(List<num> point) {
    var best = coords.keys.first;
    var distance = double.infinity;
    for (final entry in coords.entries) {
      final d = _meters(
        point[0].toDouble(),
        point[1].toDouble(),
        entry.value[0],
        entry.value[1],
      );
      if (d < distance) {
        best = entry.key;
        distance = d;
      }
    }
    return best;
  }

  final start = nearest(input.from), end = nearest(input.to);
  final dist = <int, double>{start: 0};
  final previous = <int, int>{};
  final queue = HeapPriorityQueue<_QueueEntry>(
    (a, b) => a.distance.compareTo(b.distance),
  )..add(_QueueEntry(0, start));
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    if (current.node == end) break;
    if (current.distance != dist[current.node]) continue;
    for (final next in graph[current.node] ?? const <int>[]) {
      final weight = _meters(
        coords[current.node]![0],
        coords[current.node]![1],
        coords[next]![0],
        coords[next]![1],
      );
      final candidate = current.distance + weight;
      if (candidate < (dist[next] ?? double.infinity)) {
        dist[next] = candidate;
        previous[next] = current.node;
        queue.add(_QueueEntry(candidate, next));
      }
    }
  }
  if (start != end && !previous.containsKey(end)) return [];
  final path = <int>[end];
  while (path.last != start) {
    final parent = previous[path.last];
    if (parent == null) return [];
    path.add(parent);
  }
  return [
    [input.from[0].toDouble(), input.from[1].toDouble()],
    ...path.reversed.map((id) => coords[id]!),
    [input.to[0].toDouble(), input.to[1].toDouble()],
  ];
}

double _meters(double lat1, double lon1, double lat2, double lon2) {
  const radius = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180,
      dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
