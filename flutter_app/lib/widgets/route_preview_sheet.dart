import 'package:flutter/material.dart';
import '../controllers/navigation_controller.dart';

class RoutePreviewSheet extends StatelessWidget {
  final NavigationController controller;
  final String busName;
  final String eta;
  final String distance;
  final String busEta;
  final String speed;
  final VoidCallback onStart;
  final VoidCallback onClose;
  final VoidCallback onShare;

  const RoutePreviewSheet({
    super.key,
    required this.controller,
    required this.busName,
    required this.eta,
    required this.distance,
    required this.busEta,
    required this.speed,
    required this.onStart,
    required this.onClose,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final selectedMode = controller.travelMode;
          final liveEta = controller.eta.isEmpty ? eta : controller.eta;
          final liveDistance = controller.distance.isEmpty ? distance : controller.distance;
          final modes = <(RouteTravelMode, IconData, String)>[
            (RouteTravelMode.walk, Icons.directions_walk, 'Walk'),
            (RouteTravelMode.bike, Icons.directions_bike, 'Bike'),
            (RouteTravelMode.drive, Icons.directions_car, 'Drive'),
          ];
          return Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 12,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(8))),
                    Row(children: [
                      Expanded(child: Text('Directions to $busName', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
                      IconButton(onPressed: onShare, icon: const Icon(Icons.share_outlined)),
                      IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
                    ]),
                    Row(children: [
                      for (final entry in modes)
                        Expanded(child: InkWell(
                          onTap: () => controller.setTravelMode(entry.$1),
                          child: Column(children: [
                            Icon(entry.$2, color: selectedMode == entry.$1 ? const Color(0xFF0F766E) : null),
                            Text('${entry.$3} · ${_time(entry.$1)}'),
                            Container(height: 3, margin: const EdgeInsets.only(top: 8), color: selectedMode == entry.$1 ? const Color(0xFF0F766E) : Colors.transparent),
                          ]),
                        )),
                    ]),
                    const SizedBox(height: 16),
                    Align(alignment: Alignment.centerLeft, child: Text('$liveEta ($liveDistance)', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
                    const Align(alignment: Alignment.centerLeft, child: Text('Fastest route', style: TextStyle(color: Colors.grey))),
                    if (busEta.isNotEmpty)
                      Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('Bus arrives in $busEta · moving at $speed km/h'))),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(child: FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.navigation), label: const Text('Start'))),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(onPressed: onShare, icon: const Icon(Icons.share), label: const Text('Share')),
                    ]),
                  ],
                ),
              ),
            ),
          );
        },
      );

  String _time(RouteTravelMode mode) {
    final meters = double.tryParse(distance.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
    final speed = switch (mode) { RouteTravelMode.walk => 5.0, RouteTravelMode.bike => 15.0, RouteTravelMode.drive => 25.0 };
    return '${(meters / 1000 / speed * 60).ceil()} min';
  }
}
