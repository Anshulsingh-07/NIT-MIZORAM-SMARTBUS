import 'dart:async';
import 'dart:io';

import 'package:campus_bus_tracker/services/api_service.dart';
import 'package:campus_bus_tracker/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CapturingApiService extends ApiService {
  final submittedEmails = <String>[];

  @override
  Future<Map<String, dynamic>> login(String email, String password) async {
    submittedEmails.add(email);
    return {
      'token': 'test-token',
      'user': {
        'id': 'test-user',
        'name': 'Test User',
        'email': email,
        'role': email.startsWith('caretaker-') ? 'caretaker' : 'student',
        'hostelId': 'BH1',
      },
    };
  }
}

class _SessionValidationApi extends ApiService {
  _SessionValidationApi(this.outcomes);

  final List<Object> outcomes;
  final timeouts = <Duration>[];

  @override
  Future<Map<String, dynamic>> getCurrentUser(
    String token, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    timeouts.add(timeout);
    final outcome = outcomes.removeAt(0);
    if (outcome is Map<String, dynamic>) return outcome;
    throw outcome;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('normalizes caretaker aliases without changing student email', () async {
    final api = _CapturingApiService();
    final auth = AuthService();
    addTearDown(auth.dispose);

    for (final email in [
      'caretaker_bh1',
      'caretaker-bh1',
      'caretaker_bh1@nitmz.ac.in',
      'CARETAKER-BH1@NITMZ.AC.IN',
      'student@nitmz.ac.in',
    ]) {
      expect(await auth.login(email, 'temporary-password', api), isTrue);
    }

    expect(api.submittedEmails, [
      'caretaker-bh1@nitmz.ac.in',
      'caretaker-bh1@nitmz.ac.in',
      'caretaker-bh1@nitmz.ac.in',
      'caretaker-bh1@nitmz.ac.in',
      'student@nitmz.ac.in',
    ]);
  });

  test('clears a saved session after an HTTP 401', () async {
    SharedPreferences.setMockInitialValues({
      'token': 'saved-token',
      'email': 'student@nitmz.ac.in',
      'name': 'Test Student',
      'role': 'student',
      'userId': 'student-1',
    });
    final auth = AuthService(startupRetryDelay: Duration.zero);
    final api = _SessionValidationApi([
      const ApiResponseException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
        message: 'Unauthorized',
      ),
    ]);
    addTearDown(auth.dispose);

    final result = await auth.checkAuthState(api);
    final prefs = await SharedPreferences.getInstance();

    expect(result, AuthCheckResult.unauthenticated);
    expect(prefs.getString('token'), isNull);
    expect(api.timeouts, [const Duration(seconds: 60)]);
  });

  test('clears a saved session for a 403 invalid-session response', () async {
    SharedPreferences.setMockInitialValues({
      'token': 'saved-token',
      'email': 'student@nitmz.ac.in',
    });
    final auth = AuthService(startupRetryDelay: Duration.zero);
    final api = _SessionValidationApi([
      const ApiResponseException(
        statusCode: 403,
        code: 'SESSION_EXPIRED',
        message: 'Forbidden',
      ),
    ]);
    addTearDown(auth.dispose);

    final result = await auth.checkAuthState(api);
    final prefs = await SharedPreferences.getInstance();

    expect(result, AuthCheckResult.unauthenticated);
    expect(prefs.getString('token'), isNull);
  });

  test(
    'keeps saved credentials after transient session-check failures',
    () async {
      final failures = <Object>[
        TimeoutException('request timed out'),
        const SocketException('offline'),
        const ApiResponseException(statusCode: 503, message: 'Unavailable'),
      ];

      for (final failure in failures) {
        SharedPreferences.setMockInitialValues({
          'token': 'saved-token',
          'email': 'student@nitmz.ac.in',
          'name': 'Test Student',
          'role': 'student',
          'userId': 'student-1',
        });
        final auth = AuthService(startupRetryDelay: Duration.zero);
        final api = _SessionValidationApi([failure, failure, failure]);
        addTearDown(auth.dispose);

        final result = await auth.checkAuthState(api);
        final prefs = await SharedPreferences.getInstance();

        expect(result, AuthCheckResult.unavailable);
        expect(prefs.getString('token'), 'saved-token');
        expect(prefs.getString('email'), 'student@nitmz.ac.in');
        expect(auth.error, 'Server is waking up, please try again.');
        expect(api.timeouts, [
          const Duration(seconds: 60),
          const Duration(seconds: 15),
          const Duration(seconds: 15),
        ]);
      }
    },
  );

  test('retries a transient failure and restores the saved session', () async {
    SharedPreferences.setMockInitialValues({
      'token': 'saved-token',
      'email': 'student@nitmz.ac.in',
      'name': 'Cached Student',
      'role': 'student',
      'userId': 'student-1',
    });
    final auth = AuthService(startupRetryDelay: Duration.zero);
    final api = _SessionValidationApi([
      TimeoutException('request timed out'),
      {
        'id': 'student-1',
        'name': 'Test Student',
        'email': 'student@nitmz.ac.in',
        'role': 'student',
      },
    ]);
    addTearDown(auth.dispose);

    final result = await auth.checkAuthState(api);

    expect(result, AuthCheckResult.authenticated);
    expect(auth.currentUser?.name, 'Test Student');
    expect(auth.currentUser?.token, 'saved-token');
    expect(api.timeouts, [
      const Duration(seconds: 60),
      const Duration(seconds: 15),
    ]);
  });

  test('a role-only 403 does not clear or retry the saved session', () async {
    SharedPreferences.setMockInitialValues({
      'token': 'saved-token',
      'email': 'student@nitmz.ac.in',
    });
    final auth = AuthService(startupRetryDelay: Duration.zero);
    final api = _SessionValidationApi([
      const ApiResponseException(
        statusCode: 403,
        code: 'ROLE_NOT_ALLOWED',
        message: 'Forbidden',
      ),
    ]);
    addTearDown(auth.dispose);

    final result = await auth.checkAuthState(api);
    final prefs = await SharedPreferences.getInstance();

    expect(result, AuthCheckResult.unavailable);
    expect(prefs.getString('token'), 'saved-token');
    expect(api.timeouts, [const Duration(seconds: 60)]);
  });
}
