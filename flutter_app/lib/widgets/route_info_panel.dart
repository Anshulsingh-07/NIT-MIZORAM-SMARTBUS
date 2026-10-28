import 'package:flutter/material.dart';
import '../models/route_model.dart';

class RouteInfoPanel extends StatelessWidget {
  final RouteModel? route;
  final Function(int)? onSelectRoute;

  const RouteInfoPanel({super.key, this.route, this.onSelectRoute});

  @override
  Widget build(BuildContext context) {
    if (route == null || route!.options.isEmpty) {
      return const SizedBox.shrink();
    }

    final options = route!.options;

    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 6),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Summary row for primary route
          if (options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(options.first.durationSeconds / 60).round()} min',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${(options.first.distanceMeters / 1000).toStringAsFixed(2)} km',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          for (var idx = 0; idx < options.length; idx++)
            Builder(
              builder: (context) {
                final opt = options[idx];
                final mins = (opt.durationSeconds / 60).round();
                final km = (opt.distanceMeters / 1000).toStringAsFixed(1);
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.symmetric(vertical: 6.0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    onTap: () => onSelectRoute?.call(idx),
                    leading: Icon(
                      idx == 0 ? Icons.directions_car : Icons.alt_route,
                      color: idx == 0 ? Colors.blue : Colors.grey,
                    ),
                    title: Text(
                      '$mins min',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '$km km • ${opt.summary.isNotEmpty ? opt.summary : opt.provider}',
                    ),
                    trailing: idx == 0
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
