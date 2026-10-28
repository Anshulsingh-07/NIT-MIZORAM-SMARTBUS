import 'package:campus_bus_tracker/services/api_service.dart';
import 'package:campus_bus_tracker/services/auth_service.dart';
import 'package:campus_bus_tracker/services/bus_service.dart';
import 'package:campus_bus_tracker/screens/student/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('MapScreen can unmount without throwing during dispose', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthService()),
          ChangeNotifierProvider(create: (_) => BusService()),
          Provider(create: (_) => ApiService()),
        ],
        child: const MaterialApp(home: MapScreen()),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
