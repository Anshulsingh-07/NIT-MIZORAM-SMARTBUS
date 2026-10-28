import 'package:flutter_test/flutter_test.dart';
import 'package:campus_bus_tracker/main.dart';
import 'package:campus_bus_tracker/models/models.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const CampusBusTrackerApp());
    expect(find.byType(CampusBusTrackerApp), findsOneWidget);
  });

  test('running bus creates a source-to-destination route with a clear direction', () {
    final bus = BusModel(
      busNumber: 12,
      assignedHostel: 'BH1',
      status: 'running',
      latitude: 23.7286,
      longitude: 92.7187,
      speed: 20,
    );

    final points = bus.routePoints;

    expect(points.isNotEmpty, isTrue);
    expect(points.first.latitude, closeTo(23.7286, 0.0001));
    expect(points.first.longitude, closeTo(92.7187, 0.0001));
    expect(points.last.latitude, closeTo(23.7573, 0.0001));
    expect(points.last.longitude, closeTo(92.7288, 0.0001));
  });

  test('route starts from current bus coordinate and goes toward the destination', () {
    final bus = BusModel(
      busNumber: 5,
      assignedHostel: 'BH1',
      status: 'running',
      latitude: 23.7310,
      longitude: 92.7200,
      speed: 26,
    );

    final points = bus.routePoints;

    expect(points.first.latitude, closeTo(23.7310, 0.0001));
    expect(points.first.longitude, closeTo(92.7200, 0.0001));
    expect(points.last.latitude, closeTo(23.7573, 0.0001));
    expect(points.last.longitude, closeTo(92.7288, 0.0001));
  });

  test('route labels use exact pickup and drop-off names', () {
    final toMBSE = BusModel(
      busNumber: 8,
      assignedHostel: 'BH1',
      status: 'running',
      latitude: 23.7286,
      longitude: 92.7187,
      speed: 22,
    );

    final toHostel = BusModel(
      busNumber: 8,
      assignedHostel: 'GH1',
      status: 'running',
      latitude: 23.7573,
      longitude: 92.7288,
      speed: 22,
    );

    expect(toMBSE.routeEndLabel, 'MBSE Main Gate');
    expect(toHostel.routeEndLabel, "Girls' Hostel 1");
  });
}
