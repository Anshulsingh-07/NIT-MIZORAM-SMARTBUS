import 'package:flutter/material.dart';
import '../models/bus_location.dart';

class BusBottomSheet extends StatelessWidget {
  final ScrollController scrollController;
  final BusLocation bus;
  final String route, updated, nextStop, schedule, driverName;
  final String? driverPhone;
  final bool running, showAdvanced, tracking;
  final VoidCallback? onCall;
  final VoidCallback onDirections, onStop;
  const BusBottomSheet({super.key, required this.scrollController, required this.bus, required this.route, required this.updated, required this.nextStop, required this.schedule, required this.driverName, required this.driverPhone, required this.running, required this.showAdvanced, required this.tracking, required this.onCall, required this.onDirections, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(color: theme.colorScheme.surface, elevation: 12, borderRadius: const BorderRadius.vertical(top: Radius.circular(26)), child: ListView(controller: scrollController, padding: const EdgeInsets.fromLTRB(20, 10, 20, 24), children: [
      Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: theme.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(4)))),
      const SizedBox(height: 18),
      Row(children: [const CircleAvatar(radius: 25, backgroundColor: Color(0xFFEFF6FF), child: Icon(Icons.directions_bus, color: Color(0xFF2563EB))), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(bus.busId, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)), Text(route, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))])), _chip(running)],),
      const SizedBox(height: 20),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .55), borderRadius: BorderRadius.circular(18)), child: Row(children: [Icon(running ? Icons.speed : Icons.schedule, color: const Color(0xFF2563EB)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(running ? '${bus.speed.toStringAsFixed(0)} km/h' : 'Not running right now', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)), Text('Updated $updated', style: theme.textTheme.bodySmall)]))])),
      if (driverName.isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, leading: const CircleAvatar(child: Icon(Icons.person_outline)), title: Text(driverName), subtitle: const Text('Driver'), trailing: TextButton.icon(onPressed: onCall, icon: const Icon(Icons.call), label: const Text('Call'))),
      if (running && nextStop.isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.near_me_outlined), title: Text('Next stop · $nextStop')),
      if (!running && schedule.isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.schedule), title: Text('Scheduled · $schedule')),
      const SizedBox(height: 12),
      Row(children: [Expanded(child: FilledButton.icon(onPressed: tracking ? onStop : onDirections, icon: Icon(tracking ? Icons.stop : Icons.navigation), label: Text(tracking ? 'Stop' : 'Directions'))), const SizedBox(width: 10), OutlinedButton.icon(onPressed: onCall, icon: const Icon(Icons.call_outlined), label: const Text('Call'))]),
      if (showAdvanced) ExpansionTile(title: const Text('Advanced'), leading: const Icon(Icons.tune), children: [_diag('GPS quality', '${bus.accuracy.toStringAsFixed(1)} m'), _diag('Coordinates', '${bus.lat.toStringAsFixed(5)}, ${bus.lng.toStringAsFixed(5)}')]),
    ]));
  }
  Widget _chip(bool isRunning) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: (isRunning ? const Color(0xFF16A34A) : const Color(0xFF64748B)).withValues(alpha: .12), borderRadius: BorderRadius.circular(20)), child: Text(isRunning ? 'Running' : 'Idle', style: TextStyle(color: isRunning ? const Color(0xFF15803D) : const Color(0xFF64748B), fontWeight: FontWeight.w700, fontSize: 12)));
  Widget _diag(String label, String value) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Row(children: [Expanded(child: Text(label)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))]));
}
