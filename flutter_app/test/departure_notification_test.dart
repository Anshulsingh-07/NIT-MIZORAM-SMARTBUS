import 'package:campus_bus_tracker/models/models.dart';
import 'package:campus_bus_tracker/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Departure reminder logic', () {
    test('triggers for hostel departure within two minutes', () {
      final now = DateTime(2025, 1, 1, 8, 13, 0);
      final bus = BusModel(
        busNumber: 5,
        assignedHostel: 'BH1',
        status: 'running',
        latitude: 23.7286,
        longitude: 92.7187,
        schedule: ScheduleModel(
          id: 's1',
          busNumber: 5,
          date: '2025-01-01',
          fromHostelTime: '08:15 AM',
          fromMBSETime: '05:30 PM',
        ),
      );

      final alert = NotificationService.buildDepartureAlert(
        bus: bus,
        hostelId: 'BH1',
        now: now,
      );

      expect(alert, isNotNull);
      expect(alert!.title, contains('Bus 5'));
      expect(alert.message, contains('leaving'));
    });

    test('does not trigger when departure is more than two minutes away', () {
      final now = DateTime(2025, 1, 1, 8, 10, 0);
      final bus = BusModel(
        busNumber: 5,
        assignedHostel: 'BH1',
        status: 'running',
        latitude: 23.7286,
        longitude: 92.7187,
        schedule: ScheduleModel(
          id: 's1',
          busNumber: 5,
          date: '2025-01-01',
          fromHostelTime: '08:15 AM',
          fromMBSETime: '05:30 PM',
        ),
      );

      final alert = NotificationService.buildDepartureAlert(
        bus: bus,
        hostelId: 'BH1',
        now: now,
      );

      expect(alert, isNull);
    });
  });
}
