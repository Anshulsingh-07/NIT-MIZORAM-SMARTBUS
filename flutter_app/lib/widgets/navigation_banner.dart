import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/maneuver_builder.dart';

@immutable
class NavigationTelemetry {
  final double? speedKmh;
  final String gpsStatus;

  const NavigationTelemetry({this.speedKmh, required this.gpsStatus});
}

class NavigationBanner extends StatelessWidget {
  final Maneuver? maneuver;
  final String distance;
  final bool rerouting;
  final bool routeUnavailable;
  final ValueListenable<NavigationTelemetry> telemetry;

  const NavigationBanner({
    super.key,
    required this.maneuver,
    required this.distance,
    required this.telemetry,
    this.rerouting = false,
    this.routeUnavailable = false,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xEE111827),
    elevation: 8,
    borderRadius: BorderRadius.circular(18),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Icon(_icon(maneuver?.kind), color: Colors.white, size: 38),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  routeUnavailable
                      ? 'Road route unavailable'
                      : '${maneuver?.instruction ?? 'Continue'} towards ${maneuver?.roadName ?? 'campus road'}',
                  maxLines: 2,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  routeUnavailable
                      ? 'Check connection and routing configuration'
                      : distance,
                  style: const TextStyle(color: Colors.white70),
                ),
                if (rerouting)
                  const Text(
                    'Rerouting…',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ValueListenableBuilder<NavigationTelemetry>(
            valueListenable: telemetry,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value.speedKmh == null
                      ? '-- km/h'
                      : '${value.speedKmh!.round()} km/h',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                Text(
                  value.gpsStatus,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  IconData _icon(ManeuverKind? kind) => switch (kind) {
    ManeuverKind.left => Icons.turn_left,
    ManeuverKind.right => Icons.turn_right,
    ManeuverKind.uTurn => Icons.u_turn_left,
    ManeuverKind.arrived => Icons.place,
    _ => Icons.straight,
  };
}
