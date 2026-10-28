import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Fixed-size Google Maps markers: unlike map-space circles these remain the
/// same visual size when the camera zoom changes. Alpha provides the pulse.
class PulsingDotMarker {
  static Set<Marker> build({
    required String id,
    required LatLng position,
    required bool running,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return {
      Marker(
        markerId: MarkerId(id),
        position: position,
        anchor: const Offset(.5, .5),
        alpha: running && expanded ? 1 : .78,
        icon: BitmapDescriptor.defaultMarkerWithHue(
          running ? BitmapDescriptor.hueAzure : BitmapDescriptor.hueViolet,
        ),
        onTap: onTap,
      ),
    };
  }
}
