import 'package:flutter/material.dart';

class RoutePreviewCard extends StatelessWidget {
  final String origin, destination;
  final VoidCallback onChangeDestination, onMore;
  final VoidCallback? onSwap;
  const RoutePreviewCard({super.key, required this.origin, required this.destination, required this.onChangeDestination, this.onSwap, required this.onMore});
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface, elevation: 7,
    borderRadius: BorderRadius.circular(20),
    child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 8, 10), child: Row(children: [
      Expanded(child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row(Icons.my_location, const Color(0xFF2563EB), origin, null),
        Padding(padding: const EdgeInsets.only(left: 9), child: Container(height: 14, width: 1, color: Colors.blueGrey.shade300)),
        _row(Icons.location_on, const Color(0xFFDC2626), destination, onChangeDestination),
      ])),
      IconButton(tooltip: 'Swap', onPressed: onSwap, icon: const Icon(Icons.swap_vert)),
      IconButton(tooltip: 'More options', onPressed: onMore, icon: const Icon(Icons.more_vert)),
    ])),
  );
  Widget _row(IconData icon, Color color, String text, VoidCallback? onTap) {
    final child = Row(children: [Icon(icon, size: 19, color: color), const SizedBox(width: 12), Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w600)))]);
    return SizedBox(height: 32, child: onTap == null ? child : InkWell(onTap: onTap, child: child));
  }
}
