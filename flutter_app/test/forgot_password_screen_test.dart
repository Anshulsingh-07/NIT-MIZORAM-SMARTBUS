import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:campus_bus_tracker/screens/auth/forgot_password_screen.dart';
import 'package:campus_bus_tracker/config/app_config.dart';
import 'package:campus_bus_tracker/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _RecoveryApi extends ApiService {
  String? requestedMethod;
  String? requestedDestination;
  String? requestedAccountEmail;
  String? resentEmail;
  String? verifiedEmail;
  String? verifiedMobile;
  String? verifiedOtp;
  String? resetToken;
  String? newPassword;
  String? emailOtp;
  Object? recoveryError;
  int recoveryRequestCount = 0;
  Completer<String>? recoveryCompleter;

  @override
  Future<String> requestPasswordRecovery({
    required String method,
    required String destination,
    String? accountEmail,
  }) async {
    recoveryRequestCount++;
    requestedMethod = method;
    requestedDestination = destination;
    requestedAccountEmail = accountEmail;
    if (recoveryError != null) throw recoveryError!;
    if (recoveryCompleter != null) return recoveryCompleter!.future;
    return 'If an account exists, recovery instructions will be sent.';
  }

  @override
  Future<String> requestEmailPasswordRecovery(String email) async {
    recoveryRequestCount++;
    requestedDestination = email;
    if (recoveryError != null) throw recoveryError!;
    if (recoveryCompleter != null) return recoveryCompleter!.future;
    return 'If this email is registered, a code has been sent.';
  }

  @override
  Future<void> verifyEmailPasswordRecovery({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    verifiedEmail = email;
    emailOtp = otp;
    this.newPassword = newPassword;
    if (recoveryError != null) throw recoveryError!;
  }

  @override
  Future<String> resendPasswordResetOtp(String email, String mobile) async {
    resentEmail = email;
    return 'Code requested';
  }

  @override
  Future<String> verifyPasswordResetOtp(
    String email,
    String mobile,
    String otp,
  ) async {
    verifiedEmail = email;
    verifiedMobile = mobile;
    verifiedOtp = otp;
    return 'one-time-reset-token';
  }

  @override
  Future<String> resetPassword(String token, String password) async {
    resetToken = token;
    newPassword = password;
    return 'Password reset';
  }
}

Widget _buildTestApp(_RecoveryApi api) => Provider<ApiService>.value(
  value: api,
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
            ),
            child: const Text('Sign in'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('recovery response parser handles non-JSON and malformed responses', () {
    expect(
      () => ApiService.decodeRecoveryResponse(
        http.Response(
          '<html>Not found</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      ),
      throwsException,
    );
    expect(
      () => ApiService.decodeRecoveryResponse(
        http.Response(
          '{broken',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
      throwsException,
    );
  });

  test('recovery parser reports 404, 429, and 500 without parsing success', () {
    expect(
      () => ApiService.decodeRecoveryResponse(
        http.Response(
          '{"error":"Not found"}',
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('not available on this server yet'),
        ),
      ),
    );
    for (final response in [
      http.Response(
        '{"code":"RATE_LIMITED"}',
        429,
        headers: {'content-type': 'application/json'},
      ),
      http.Response(
        '<html>Unavailable</html>',
        500,
        headers: {'content-type': 'text/html'},
      ),
    ]) {
      expect(
        () => ApiService.decodeRecoveryResponse(response),
        throwsException,
      );
    }
  });

  test('recovery parser accepts a delivery-unconfirmed 202 acknowledgement', () {
    final response = ApiService.decodeRecoveryResponse(
      http.Response(
        '{"accepted":true,"deliveryConfirmed":false,"code":"RECOVERY_ACCEPTED"}',
        202,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(response['accepted'], isTrue);
    expect(response['deliveryConfirmed'], isFalse);
    expect(response['code'], 'RECOVERY_ACCEPTED');
  });

  test('recovery parser accepts only a successful JSON object', () {
    expect(
      ApiService.decodeRecoveryResponse(
        http.Response(
          '{"success":true,"accepted":true}',
          202,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      {'success': true, 'accepted': true},
    );
  });

  test('defaults to the production SmartBus backend', () {
    expect(
      ApiService.baseUrl,
      'https://nit-mizoram-campus-bus-service.onrender.com/api',
    );
    expect(
      AppConfig.apiBaseUrl,
      'https://nit-mizoram-campus-bus-service.onrender.com',
    );
  });

  testWidgets('rejected email request stays out of OTP verification', (
    tester,
  ) async {
    final api = _RecoveryApi()
      ..recoveryError = Exception('Email service is temporarily unavailable.');
    await tester.pumpWidget(_buildTestApp(api));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).at(0),
      'caretaker-bh1@nitmz.ac.in',
    );
    await tester.tap(find.text('Send reset link'));
    await tester.pump();

    expect(
      find.textContaining('Email service is temporarily unavailable'),
      findsOneWidget,
    );
    expect(find.text('Verify your number'), findsNothing);
  });

  testWidgets('college email recovery shows generic instructions', (
    tester,
  ) async {
    final api = _RecoveryApi();
    await tester.pumpWidget(_buildTestApp(api));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'student@nitmz.ac.in');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(api.requestedMethod, 'email');
    expect(api.requestedDestination, 'student@nitmz.ac.in');
    expect(find.text('Recovery request accepted'), findsOneWidget);
    expect(find.text('Mobile OTP'), findsNothing);
  });

  testWidgets('a pending email request cannot be submitted twice', (
    tester,
  ) async {
    final api = _RecoveryApi()..recoveryCompleter = Completer<String>();
    await tester.pumpWidget(_buildTestApp(api));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).at(0),
      'caretaker-bh1@nitmz.ac.in',
    );
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pump();

    expect(api.recoveryRequestCount, 1);
    api.recoveryCompleter!.complete('Recovery queued');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Recovery request accepted'), findsOneWidget);
  });

  testWidgets(
    'recovery timeout displays friendly text instead of Dart details',
    (tester) async {
      final api = _RecoveryApi()
        ..recoveryError = TimeoutException(
          'Future not completed',
          const Duration(seconds: 10),
        );
      await tester.pumpWidget(_buildTestApp(api));
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'caretaker-bh1@nitmz.ac.in',
      );
      await tester.tap(find.text('Send reset link'));
      await tester.pump();

      expect(
        find.text(
          'The server is taking longer than expected. Please try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('TimeoutException'), findsNothing);
      expect(find.textContaining('Future not completed'), findsNothing);
    },
  );

  testWidgets('college email recovery directs user to the reset link', (
    tester,
  ) async {
    final api = _RecoveryApi();
    await tester.pumpWidget(_buildTestApp(api));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).at(0),
      'caretaker-bh1@nitmz.ac.in',
    );
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Recovery request accepted'), findsOneWidget);
    expect(
      find.textContaining('reset link will arrive'),
      findsOneWidget,
    );
    expect(api.requestedMethod, 'email');
    expect(api.requestedDestination, 'caretaker-bh1@nitmz.ac.in');
    await tester.tap(find.text('Back to login'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });
}
