import 'package:flutter/material.dart';

class NavigationBottomBar extends StatelessWidget {
  final String eta, distance, arrival, travelled;
  final VoidCallback onEnd, onShare;
  const NavigationBottomBar({
    super.key,
    required this.eta,
    required this.distance,
    required this.arrival,
    required this.travelled,
    required this.onEnd,
    required this.onShare,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF111827),
    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: onEnd,
              icon: const Icon(Icons.close),
              tooltip: 'End navigation',
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    eta,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '$distance remaining · $arrival',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  Text(
                    '$travelled travelled',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              onPressed: onShare,
              icon: const Icon(Icons.share),
              tooltip: 'Share ETA',
            ),
          ],
        ),
      ),
    ),
  );
}
