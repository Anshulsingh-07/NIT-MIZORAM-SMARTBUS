import 'dart:async';

import 'package:campus_bus_tracker/services/api_service.dart';
import 'package:campus_bus_tracker/screens/student/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApiService extends ApiService {
  bool shouldFail = false;
  bool called = false;
  Completer<Map<String, dynamic>>? pendingResponse;
  String? lastMessage;
  String? lastCategory;
  int? lastBusNumber;

  @override
  Future<Map<String, dynamic>> login(String email, String password) async {
    return {
      'token': 'fake-token',
      'user': {
        'id': 'u1',
        'name': 'Test Student',
        'email': email,
        'role': 'student',
        'hostelId': 'BH1',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> submitReport(
    String token, {
    required String message,
    String category = 'other',
    int? busNumber,
  }) async {
    called = true;
    lastMessage = message;
    lastCategory = category;
    lastBusNumber = busNumber;
    if (pendingResponse != null) return pendingResponse!.future;
    if (shouldFail) {
      throw Exception('Network error');
    }
    return {
      'status': 'success',
      'data': {
        'id': 'report-1',
        'reporterId': 'u1',
        'hostelId': 'BH1',
        'busNumber': busNumber,
        'category': category,
        'message': message,
        'status': 'open',
        'createdAt': '2026-10-10T00:00:00.000Z',
      },
    };
  }
}

void main() {
  testWidgets('BusIssueReportDialog shows loading state and disables submit', (tester) async {
    final api = _FakeApiService()
      ..pendingResponse = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: api,
        child: const MaterialApp(
          home: BusIssueReportDialog(
            token: 'token-1',
            busKey: 'Bus 5',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Delayed bus');
  await tester.pump();
  expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(find.text('Sending...'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(api.called, isTrue);

    api.pendingResponse!.complete({'status': 'success'});
    await tester.pumpAndSettle();
  });

  testWidgets('BusIssueReportDialog shows success message after API success', (tester) async {
    final api = _FakeApiService();
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: api,
        child: const MaterialApp(
          home: BusIssueReportDialog(
            token: 'token-1',
            busKey: 'Bus 5',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Bus is late');
  await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Report submitted successfully.'), findsOneWidget);
    expect(find.text('Bus is late'), findsNothing);
  });

  testWidgets('BusIssueReportDialog keeps input and shows error after API failure', (tester) async {
    final api = _FakeApiService()..shouldFail = true;
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: api,
        child: const MaterialApp(
          home: BusIssueReportDialog(
            token: 'token-1',
            busKey: 'Bus 5',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Need retry');
  await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Could not submit report. Please try again.'), findsOneWidget);
    expect(find.text('Need retry'), findsOneWidget);
  });
}
