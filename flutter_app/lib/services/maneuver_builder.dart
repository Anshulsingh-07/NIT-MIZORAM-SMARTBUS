import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';

enum ManeuverKind { straight, left, right, uTurn, arrived }
class Maneuver {
  final ManeuverKind kind;
  final LatLng point;
  final String roadName;
  final double distanceMeters;
  const Maneuver(this.kind, this.point, this.roadName, this.distanceMeters);
  String get instruction => switch (kind) {
    ManeuverKind.left => 'Turn left', ManeuverKind.right => 'Turn right',
    ManeuverKind.uTurn => 'Make a U-turn', ManeuverKind.arrived => 'Arrived',
    ManeuverKind.straight => 'Continue',
  };
  String get iconName => switch (kind) {
    ManeuverKind.left => 'turn_left', ManeuverKind.right => 'turn_right',
    ManeuverKind.uTurn => 'u_turn_left', ManeuverKind.arrived => 'place',
    ManeuverKind.straight => 'straight',
  };
}

List<Maneuver> buildManeuvers(List<LatLng> points) {
  if (points.length < 2) return const [];
  final result = <Maneuver>[];
  var distance = 0.0;
  for (var i = 1; i < points.length; i++) {
    distance += _meters(points[i - 1], points[i]);
    if (i < points.length - 1) {
      final change = (_bearing(points[i - 1], points[i + 1]) - _bearing(points[i - 1], points[i]) + 540) % 360 - 180;
      if (change.abs() >= 20) {
        final kind = change.abs() > 120 ? ManeuverKind.uTurn : change < 0 ? ManeuverKind.left : ManeuverKind.right;
        result.add(Maneuver(kind, points[i], 'Campus road', distance));
        distance = 0;
      }
    }
  }
  result.add(Maneuver(ManeuverKind.arrived, points.last, 'Destination', distance));
  return result;
}

double _bearing(LatLng a, LatLng b) {
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  return (math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)) * 180 / math.pi + 360) % 360;
}
double _meters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dp = p2 - p1, dl = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}
