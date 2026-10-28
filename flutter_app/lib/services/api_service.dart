import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';
import '../models/bus_location.dart';
import 'authenticated_stream_coordinator.dart';

class ApiResponseException implements Exception {
  const ApiResponseException({
    required this.statusCode,
    required this.message,
    this.code,
  });

  final int statusCode;
  final String message;
  final String? code;

  @override
  String toString() => message;
}

class ApiService {
  static String get baseUrl => _normalizeApiBase(AppConfig.apiBaseUrl);
  static String get _configuredHost =>
      Uri.tryParse(baseUrl)?.host ?? 'unknown host';
  static String get trackingBaseUrl => baseUrl;
  static String get trackingLatestEndpoint => '$baseUrl/location/latest';
  static const Duration _telemetryEndpointBackoff = Duration(seconds: 45);
  static const Duration _recoveryConnectTimeout = Duration(seconds: 15);
  static const Duration _recoveryResponseTimeout = Duration(seconds: 10);
  static const Duration _recoveryOverallTimeout = Duration(seconds: 30);
  static final Map<String, DateTime> _telemetryBackoffUntil = {};
  static final AuthenticatedStreamCoordinator<List<Map<String, dynamic>>>
  _busStreamCoordinator = AuthenticatedStreamCoordinator(
    (token) => ApiService()._openBusConnection(token),
  );

  static String _normalizeApiBase(String rawBase) {
    var base = rawBase.trim();
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.endsWith('/api')) {
      base = '$base/api';
    }
    return base;
  }

  static String _unreachableServerMessage(String message) {
    if (!kDebugMode) return message;
    return '$message (host: $_configuredHost)';
  }

  Future<void> checkHealthAtStartup() async {
    final uri = Uri.parse('$baseUrl/health');
    final safeUri = uri.replace(userInfo: '', query: '', fragment: '');
    if (kDebugMode) {
      debugPrint('Startup health check GET $safeUri');
    }
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (kDebugMode) {
        debugPrint('Startup health check $safeUri -> ${response.statusCode}');
      }
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Startup health check failed for $_configuredHost: ${error.runtimeType}',
        );
      }
    }
  }

  static Future<BusLocation?> fetchLatestLocation({
    required String token,
  }) async {
    final endpoint = '$baseUrl/location/latest';

    final now = DateTime.now();
    final backoffUntil = _telemetryBackoffUntil[endpoint];
    if (backoffUntil != null && now.isBefore(backoffUntil)) {
      throw Exception('Location service retry backoff is active');
    }

    try {
      final response = await http
          .get(Uri.parse(endpoint), headers: _headers(token))
          .timeout(const Duration(seconds: 4));
      if (kDebugMode) {
        debugPrint('Telemetry GET $endpoint -> ${response.statusCode}');
      }
      final data = _decodeJsonResponse(response);
      if (response.statusCode == 200) {
        if (data is Map<String, dynamic>) {
          _telemetryBackoffUntil.remove(endpoint);
          if (data.containsKey('data') && data['data'] == null) return null;
          final payload = data['data'] is Map<String, dynamic>
              ? data['data'] as Map<String, dynamic>
              : data;
          final location = BusLocation.fromJson(payload);
          if (kDebugMode) {
            debugPrint(
              'Telemetry parsed from $endpoint: '
              'bus=${location.busId}, lat=${location.lat}, lng=${location.lng}, speed=${location.speed}',
            );
          }
          return location;
        }
      }

      throw Exception(
        data is Map<String, dynamic>
            ? (data['error']?.toString() ?? 'Location request failed')
            : 'Location request failed',
      );
    } catch (e) {
      _telemetryBackoffUntil[endpoint] = DateTime.now().add(
        _telemetryEndpointBackoff,
      );
      if (kDebugMode) {
        debugPrint('Telemetry fetch failed for $endpoint: $e');
      }
      rethrow;
    }
  }

  static Future<List<BusLocation>> getAllBusesLocations({String? token}) async {
    final buses = await ApiService().getBuses(token: token);
    return buses
        .whereType<Map<String, dynamic>>()
        .map(BusLocation.fromJson)
        .toList();
  }

  static Map<String, String> _headers([String? token]) {
    final headers = {'Content-Type': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return headers;
  }

  static String _unexpectedServerResponseMessage() =>
      'Unexpected server response — please try again.';

  static Map<String, dynamic> decodeRecoveryResponse(http.Response response) {
    final status = response.statusCode;
    if (status == 404) {
      throw Exception(
        'Password recovery is not available on this server yet. Please try again later.',
      );
    }
    if (status == 401) {
      throw Exception('We could not verify that request. Please try again.');
    }
    if (status == 429) {
      throw Exception('Too many attempts. Please wait a little and try again.');
    }
    if (status >= 500) {
      throw Exception(
        'The service is temporarily unavailable. Please try again.',
      );
    }

    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    final isJson =
        contentType.contains('application/json') ||
        contentType.contains('+json');
    if (!isJson) {
      if (status >= 400) {
        throw Exception(
          'Unable to complete password recovery. Please try again.',
        );
      }
      throw Exception(
        'The server returned an invalid response. Please try again.',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception(
        'The server returned an invalid response. Please try again.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'The server returned an invalid response. Please try again.',
      );
    }

    if (status == 400) {
      throw Exception(
        decoded['message']?.toString() ??
            decoded['error']?.toString() ??
            'Check the details and try again.',
      );
    }
    final acceptedWithoutDeliveryConfirmation =
        status == 202 &&
        decoded['accepted'] == true &&
        decoded['deliveryConfirmed'] == false;
    if (status < 200 ||
        status >= 300 ||
        (decoded['success'] != true && !acceptedWithoutDeliveryConfirmation)) {
      final message = decoded['message']?.toString();
      throw Exception(
        message ?? 'Unable to complete password recovery. Please try again.',
      );
    }
    return decoded;
  }

  static String _recoveryResponseSummary(http.Response response) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    final body = response.body.trim();
    final isJson =
        contentType.contains('application/json') ||
        contentType.contains('+json');
    if (isJson) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final code = decoded['code'];
          final safeCode =
              code is String && RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(code)
              ? code
              : 'other';
          final safeKeys = decoded.keys
              .where(
                (key) => RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,40}$').hasMatch(key),
              )
              .take(12)
              .join(',');
          final success = decoded['success'];
          return 'json keys=$safeKeys '
              'code=$safeCode '
              'success=${success is bool ? success : 'unspecified'}';
        }
        return 'json shape=${decoded.runtimeType}';
      } on FormatException {
        return 'invalid-json bytes=${response.bodyBytes.length}';
      }
    }
    if (body.isEmpty) return 'empty-body';
    if (body.startsWith('<!doctype html') || body.startsWith('<html')) {
      return 'html bytes=${response.bodyBytes.length}';
    }
    return 'non-json bytes=${response.bodyBytes.length}';
  }

  static void _debugPrintResponse(
    String method,
    Uri uri,
    http.Response response,
  ) {
    if (kDebugMode) {
      debugPrint(
        '$method $uri -> ${response.statusCode} ${response.headers['content-type'] ?? 'unknown'}',
      );
    }
  }

  static dynamic _decodeJsonResponse(http.Response response) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    final body = response.body.trim();
    if (contentType.isEmpty &&
        body.isNotEmpty &&
        !body.startsWith('{') &&
        !body.startsWith('[')) {
      throw Exception(_unexpectedServerResponseMessage());
    }
    if (!contentType.contains('application/json') &&
        !contentType.contains('+json') &&
        !body.startsWith('{') &&
        !body.startsWith('[')) {
      throw Exception(_unexpectedServerResponseMessage());
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw Exception(_unexpectedServerResponseMessage());
    }
  }

  Future<void> logout(String token) async {
    cancelBusStream(token);
    await http
        .post(Uri.parse('$baseUrl/auth/logout'), headers: _headers(token))
        .timeout(const Duration(seconds: 8));
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final uri = Uri.parse('$baseUrl/auth/login');
    if (kDebugMode) debugPrint('Login request URL: $uri');
    try {
      final response = await http
          .post(
            uri,
            headers: _headers(),
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));
      _debugPrintResponse('POST', uri, response);
      final data = _decodeJsonResponse(response);
      if (response.statusCode == 200 && data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map<String, dynamic>) {
        throw Exception(data['error'] ?? 'Invalid email or password');
      }
      throw Exception(_unexpectedServerResponseMessage());
    } catch (e) {
      if (e is TimeoutException || e is http.ClientException) {
        throw Exception(
          _unreachableServerMessage(
            'Could not reach the sign-in server. Check your connection and try again.',
          ),
        );
      }
      rethrow;
    }
  }

  Future<String> requestPasswordRecovery({
    required String method,
    required String destination,
    String? accountEmail,
  }) async {
    final normalizedMethod = method.trim().toLowerCase();
    final value = destination.trim();
    final payload = normalizedMethod == 'email'
        ? {'method': normalizedMethod, 'email': value.toLowerCase()}
        : {
            'method': normalizedMethod,
            'email': accountEmail?.trim().toLowerCase() ?? '',
            'mobile': value,
          };
    final data = await _postRecoveryJson('/auth/forgot-password', payload);
    return data['message']?.toString() ??
        'If an account exists for these details, recovery instructions will be sent.';
  }

  Future<String> forgotPassword(String email) =>
      requestPasswordRecovery(method: 'email', destination: email);

  Future<String> requestEmailPasswordRecovery(String email) async {
    final data = await _postRecoveryJson('/auth/password-recovery/request', {
      'email': email.trim().toLowerCase(),
    });
    return data['message']?.toString() ??
        'If this email is registered, a code has been sent.';
  }

  Future<void> verifyEmailPasswordRecovery({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    await _postRecoveryJson('/auth/password-recovery/verify', {
      'email': email.trim().toLowerCase(),
      'otp': otp.trim(),
      'newPassword': newPassword,
    });
  }

  Future<String> resendPasswordResetOtp(String email, String mobile) async {
    final data = await _postRecoveryJson('/auth/resend-otp', {
      'email': email.trim().toLowerCase(),
      'mobile': mobile.trim(),
    });
    return data['message']?.toString() ??
        'If an account exists for these details, recovery instructions will be sent.';
  }

  Future<String> verifyPasswordResetOtp(
    String email,
    String mobile,
    String otp,
  ) async {
    final data = await _postRecoveryJson('/auth/verify-otp', {
      'email': email.trim().toLowerCase(),
      'mobile': mobile.trim(),
      'otp': otp.trim(),
    });
    final token = data['resetToken']?.toString();
    if (token != null && token.isNotEmpty) return token;
    throw Exception('The server returned an invalid reset response.');
  }

  Future<String> resetPassword(String token, String newPassword) async {
    final data = await _postRecoveryJson('/auth/reset-password', {
      'token': token,
      'newPassword': newPassword,
    });
    return data['message']?.toString() ??
        'Your password has been reset successfully. Please log in using your new password.';
  }

  Future<Map<String, dynamic>> _postRecoveryJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final client = http.Client();
    final stopwatch = Stopwatch()..start();
    final request = http.Request('POST', Uri.parse('$baseUrl$path'))
      ..headers.addAll(_headers())
      ..body = jsonEncode(payload);

    Future<Map<String, dynamic>> performRequest() async {
      try {
        final streamedResponse = await client
            .send(request)
            .timeout(_recoveryConnectTimeout);
        final response = await http.Response.fromStream(
          streamedResponse,
        ).timeout(_recoveryResponseTimeout);
        if (kDebugMode) {
          debugPrint(
            'Recovery POST ${request.url.path} status=${response.statusCode} '
            'contentType=${response.headers['content-type'] ?? 'missing'} '
            'durationMs=${stopwatch.elapsedMilliseconds} '
            'response=${_recoveryResponseSummary(response)}',
          );
        }
        return decodeRecoveryResponse(response);
      } on TimeoutException {
        if (kDebugMode) {
          debugPrint(
            'Recovery POST ${request.url.path} timeout '
            'durationMs=${stopwatch.elapsedMilliseconds}',
          );
        }
        rethrow;
      } on http.ClientException catch (error) {
        if (kDebugMode) {
          debugPrint(
            'Recovery POST ${request.url.path} networkError=${error.runtimeType} '
            'durationMs=${stopwatch.elapsedMilliseconds}',
          );
        }
        rethrow;
      }
    }

    try {
      return await performRequest().timeout(_recoveryOverallTimeout);
    } on TimeoutException {
      throw Exception(
        'The server is taking longer than expected. Please try again.',
      );
    } on http.ClientException {
      throw Exception('Unable to connect to the server. Please try again.');
    } finally {
      client.close();
    }
  }

  Future<void> changePassword(
    String token,
    String currentPassword,
    String newPassword,
  ) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/auth/change-password'),
          headers: _headers(token),
          body: jsonEncode({
            'currentPassword': currentPassword,
            'newPassword': newPassword,
          }),
        )
        .timeout(const Duration(seconds: 10));
    final data = response.body.isNotEmpty
        ? _decodeJsonResponse(response)
        : null;
    if (response.statusCode == 200) return;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not update password'
          : 'Could not update password',
    );
  }

  Future<Map<String, dynamic>> submitReport(
    String token, {
    required String message,
    String category = 'other',
    int? busNumber,
  }) async {
    final uri = Uri.parse('$baseUrl/reports');
    final payload = {
      'category': category,
      'message': message.trim(),
      if (busNumber != null) 'busNumber': busNumber,
    };

    try {
      final response = await http
          .post(uri, headers: _headers(token), body: jsonEncode(payload))
          .timeout(const Duration(seconds: 10));
      _debugPrintResponse('POST', uri, response);
      final data = response.body.isNotEmpty
          ? _decodeJsonResponse(response)
          : <String, dynamic>{};
      if (response.statusCode == 201 || response.statusCode == 200) {
        if (data is Map<String, dynamic>) {
          return data;
        }
        throw Exception(_unexpectedServerResponseMessage());
      }
      if (data is Map<String, dynamic>) {
        throw ApiResponseException(
          statusCode: response.statusCode,
          code: data['code']?.toString(),
          message: data['error']?.toString() ?? 'Could not submit report',
        );
      }
      throw Exception(_unexpectedServerResponseMessage());
    } on TimeoutException {
      throw Exception(
        'The report could not be sent because the server timed out.',
      );
    } on http.ClientException {
      throw Exception(
        _unreachableServerMessage(
          'Your device is offline or the server is unreachable.',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> driverLogin(String phone, String pin) async {
    final uri = Uri.parse('$baseUrl/auth/driver-login');
    if (kDebugMode) debugPrint('Driver login request URL: $uri');
    try {
      final response = await http
          .post(
            uri,
            headers: _headers(),
            body: jsonEncode({'phone': phone, 'pin': pin}),
          )
          .timeout(const Duration(seconds: 60));
      _debugPrintResponse('POST', uri, response);
      final data = _decodeJsonResponse(response);
      if (response.statusCode == 200 && data is Map<String, dynamic>) {
        return data;
      }
      final message = data is Map<String, dynamic> ? data['error'] : null;
      throw Exception(message ?? 'Driver login failed');
    } on TimeoutException {
      throw Exception(
        'Server is waking up. Please wait a moment and try again.',
      );
    } on http.ClientException {
      throw Exception(
        _unreachableServerMessage(
          'Could not reach the server. It may be waking up; please try again shortly.',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> getDriverCurrentUser(
    String token, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await http
        .get(Uri.parse('$baseUrl/auth/driver/me'), headers: _headers(token))
        .timeout(timeout);
    final data = _tryDecodeJson(response.body);
    if (response.statusCode == 200 &&
        data is Map<String, dynamic> &&
        data['user'] is Map<String, dynamic>) {
      return data['user'] as Map<String, dynamic>;
    }
    throw ApiResponseException(
      statusCode: response.statusCode,
      code: data is Map<String, dynamic> ? data['code']?.toString() : null,
      message: data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not verify driver session'
          : 'Could not verify driver session',
    );
  }

  Future<int> sendDriverLocation(Map<String, dynamic> fix, String token) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/location'),
          headers: _headers(token),
          body: jsonEncode(fix),
        )
        .timeout(const Duration(seconds: 8));
    return response.statusCode;
  }

  Stream<List<Map<String, dynamic>>> streamBusUpdates(
    String token, {
    required bool Function() isSessionValid,
    required Future<void> Function() onUnauthorized,
  }) => _busStreamCoordinator.subscribe(
    token,
    isSessionValid: isSessionValid,
    onUnauthorized: onUnauthorized,
  );

  static void cancelBusStream([String? token]) =>
      _busStreamCoordinator.cancel(token);

  Stream<List<Map<String, dynamic>>> _openBusConnection(String token) async* {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$baseUrl/buses/stream'))
        ..headers.addAll(_headers(token))
        ..headers['Accept'] = 'text/event-stream';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 401) {
        throw const StreamUnauthorizedException();
      }
      if (response.statusCode != 200) {
        throw Exception('Bus stream returned ${response.statusCode}');
      }

      final eventLines = <String>[];
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.startsWith('data:')) {
          eventLines.add(line.substring(5).trimLeft());
        } else if (line.isEmpty && eventLines.isNotEmpty) {
          final decoded = jsonDecode(eventLines.join('\n'));
          eventLines.clear();
          if (decoded is List) {
            yield decoded.whereType<Map<String, dynamic>>().toList();
          }
        }
      }
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> getCurrentUser(
    String token, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await http
        .get(Uri.parse('$baseUrl/me'), headers: _headers(token))
        .timeout(timeout);

    final data = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && data is Map<String, dynamic>) {
      final user = data['user'];
      if (user is Map<String, dynamic>) return user;
      throw const ApiResponseException(
        statusCode: 502,
        message: 'Could not verify user session',
      );
    }

    throw ApiResponseException(
      statusCode: response.statusCode,
      code: data is Map<String, dynamic> ? data['code']?.toString() : null,
      message: data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not verify user session'
          : 'Could not verify user session',
    );
  }

  Future<Map<String, dynamic>> getApiRoot() async {
    final response = await http
        .get(Uri.parse(baseUrl))
        .timeout(const Duration(seconds: 8));
    final data = response.body.isNotEmpty
        ? _decodeJsonResponse(response)
        : <String, dynamic>{};
    if (response.statusCode == 200 && data is Map<String, dynamic>) return data;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'API unavailable'
          : 'API unavailable',
    );
  }

  Future<Map<String, dynamic>> getHealth() async {
    final response = await http
        .get(Uri.parse('$baseUrl/health'))
        .timeout(const Duration(seconds: 8));
    if (kDebugMode) {
      debugPrint('Health check $baseUrl/health -> ${response.statusCode}');
    }
    final data = response.body.isNotEmpty
        ? _decodeJsonResponse(response)
        : <String, dynamic>{};
    if (response.statusCode == 200 && data is Map<String, dynamic>) return data;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'Health check failed'
          : 'Health check failed',
    );
  }

  Future<List<dynamic>> getHostels() async {
    final response = await http
        .get(Uri.parse('$baseUrl/hostels'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      final parsed = _decodeJsonResponse(response);
      if (parsed is List) return parsed;
      if (parsed is Map<String, dynamic>) {
        final data = parsed['data'];
        if (data is List) return data;
      }
    }
    throw Exception('Failed to load hostels');
  }

  Future<List<dynamic>> getTelemetryDiagnostics({
    String? busId,
    int limit = 50,
    String? token,
  }) async {
    final segments = <String>[];
    if (busId != null && busId.isNotEmpty) segments.add('bus_id=$busId');
    if (limit > 0) segments.add('limit=$limit');
    final url = segments.isEmpty
        ? '$baseUrl/telemetry/diagnostics'
        : '$baseUrl/telemetry/diagnostics?${segments.join('&')}';
    final response = await http
        .get(Uri.parse(url), headers: _headers(token))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      final parsed = _decodeJsonResponse(response);
      if (parsed is List) return parsed;
      if (parsed is Map<String, dynamic>) {
        final data = parsed['data'];
        if (data is List) return data;
      }
    }
    throw Exception('Failed to load telemetry diagnostics');
  }

  Future<List<dynamic>> getTelemetryHistory({
    String? busId,
    String? token,
  }) async {
    final query = busId != null && busId.isNotEmpty ? '?bus_id=$busId' : '';
    final response = await http
        .get(
          Uri.parse('$baseUrl/telemetry/history$query'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      final parsed = _decodeJsonResponse(response);
      if (parsed is List) return parsed;
      if (parsed is Map<String, dynamic>) {
        final data = parsed['data'];
        if (data is List) return data;
      }
    }
    throw Exception('Failed to load telemetry history');
  }

  Future<String> requestRegistrationMobileOtp(
    String email,
    String mobile,
  ) async {
    final data = await _postRecoveryJson('/auth/registration-mobile/request', {
      'email': email.trim().toLowerCase(),
      'mobile': mobile.trim(),
    });
    return data['message']?.toString() ?? 'Verification code sent.';
  }

  Future<String> verifyRegistrationMobileOtp(
    String email,
    String mobile,
    String otp,
  ) async {
    final data = await _postRecoveryJson('/auth/registration-mobile/verify', {
      'email': email.trim().toLowerCase(),
      'mobile': mobile.trim(),
      'otp': otp.trim(),
    });
    final token = data['verificationToken']?.toString();
    if (token != null && token.isNotEmpty) return token;
    throw Exception('The server returned an invalid verification response.');
  }

  Future<Map<String, dynamic>> register(
    String name,
    String email,
    String mobile,
    String password,
    String confirmPassword,
    String hostelId,
    String mobileVerificationToken,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/auth/register'),
            headers: _headers(),
            body: jsonEncode({
              'name': name,
              'email': email,
              'mobile': mobile,
              'password': password,
              'confirmPassword': confirmPassword,
              'hostelId': hostelId,
              'mobileVerificationToken': mobileVerificationToken,
            }),
          )
          .timeout(const Duration(seconds: 10));
      final data = _decodeJsonResponse(response);
      if (response.statusCode == 200 || response.statusCode == 201) return data;
      throw Exception(data['error'] ?? 'Registration failed');
    } catch (e) {
      if (e is TimeoutException || e is http.ClientException) {
        throw Exception('Could not reach the registration server. Try again.');
      }
      rethrow;
    }
  }

  Future<List<dynamic>> getBuses({String? hostel, String? token}) async {
    if (token == null || token.isEmpty) {
      throw Exception('Not logged in. Sign in again to load buses.');
    }

    final query = hostel == null
        ? ''
        : '?hostel=${Uri.encodeQueryComponent(hostel)}';
    final endpoints = ['$baseUrl/buses$query', '$baseUrl/all-buses$query'];
    Object? lastError;
    var requestCount = 0;

    for (
      var endpointIndex = 0;
      endpointIndex < endpoints.length && requestCount < 3;
      endpointIndex++
    ) {
      final url = endpoints[endpointIndex];
      var endpointRetries = 0;
      var retryCurrentEndpoint = true;
      while (retryCurrentEndpoint && requestCount < 3) {
        requestCount++;
        retryCurrentEndpoint = false;
        final timeout = Duration(seconds: requestCount == 1 ? 60 : 15);
        http.Response response;
        try {
          response = await http
              .get(Uri.parse(url), headers: _headers(token))
              .timeout(timeout);
        } on TimeoutException {
          lastError = Exception(
            'Server request timed out after ${timeout.inSeconds}s',
          );
          if (kDebugMode) {
            debugPrint('Bus fetch timeout for $url (${timeout.inSeconds}s)');
          }
          if (endpointRetries == 0 && requestCount < 3) {
            endpointRetries++;
            await Future<void>.delayed(const Duration(seconds: 1));
            retryCurrentEndpoint = true;
            continue;
          }
          break;
        } on http.ClientException catch (error) {
          lastError = Exception('Network error: ${error.message}');
          if (kDebugMode) {
            debugPrint('Bus fetch network error for $url: ${error.message}');
          }
          if (endpointRetries == 0 && requestCount < 3) {
            endpointRetries++;
            await Future<void>.delayed(const Duration(seconds: 1));
            retryCurrentEndpoint = true;
            continue;
          }
          break;
        }

        if (response.statusCode == 200) {
          final decoded = _decodeJsonResponse(response);
          final items = decoded is List
              ? decoded
              : decoded is Map<String, dynamic>
              ? decoded['data'] ?? decoded['buses']
              : null;
          if (items is List) return List<dynamic>.from(items);
          lastError = const FormatException('Unexpected buses response format');
          _logBusFetchFailure(url, response, lastError);
          break;
        }

        _logBusFetchFailure(url, response, 'HTTP ${response.statusCode}');
        final decoded = response.body.isEmpty
            ? null
            : _tryDecodeJson(response.body);
        final serverMessage = decoded is Map<String, dynamic>
            ? decoded['error']?.toString()
            : null;
        if (response.statusCode == 401) {
          throw Exception(
            serverMessage ?? 'Session expired. Please sign in again.',
          );
        }
        if (response.statusCode == 403) {
          throw Exception(
            serverMessage ?? 'You are not allowed to view these buses.',
          );
        }

        lastError = Exception(
          serverMessage ??
              'Bus request failed with HTTP ${response.statusCode}',
        );
        if (response.statusCode == 404 &&
            endpointIndex + 1 < endpoints.length) {
          break;
        }
        if (response.statusCode >= 500 &&
            endpointRetries == 0 &&
            requestCount < 3) {
          endpointRetries++;
          await Future<void>.delayed(const Duration(seconds: 1));
          retryCurrentEndpoint = true;
          continue;
        }
        break;
      }
    }

    throw Exception(
      lastError?.toString() ?? 'Could not load buses. Please retry.',
    );
  }

  static dynamic _tryDecodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static void _logBusFetchFailure(
    String url,
    http.Response response,
    Object error,
  ) {
    if (!kDebugMode) return;
    final body = response.body.length > 600
        ? '${response.body.substring(0, 600)}…'
        : response.body;
    debugPrint(
      'Bus fetch failed: $url -> ${response.statusCode}; $error; body=$body',
    );
  }

  Future<Map<String, dynamic>?> getBus(int busNumber, {String? token}) async {
    final response = await http
        .get(Uri.parse('$baseUrl/buses/$busNumber'), headers: _headers(token))
        .timeout(const Duration(seconds: 8));
    final data = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && data is Map<String, dynamic>) {
      return data;
    }
    throw Exception(
      data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not load bus'
          : 'Could not load bus',
    );
  }

  Future<List<dynamic>> getTodayScheduledBuses({
    required String token,
    DateTime? date,
  }) async {
    final day = date ?? DateTime.now();
    final dateText =
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final response = await http
        .get(
          Uri.parse('$baseUrl/today-buses?date=$dateText'),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 10));
    final data = _decodeJsonResponse(response);
    if (response.statusCode == 200 && data is List) return data;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not load today’s buses'
          : 'Could not load today’s buses',
    );
  }

  Future<List<dynamic>> getSchedules({
    String? hostel,
    String? date,
    String? token,
  }) async {
    final query = <String, String>{};
    if (date != null) query['date'] = date;
    if (hostel != null) query['hostel'] = hostel;
    final uri = Uri.parse(
      '$baseUrl/schedules',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final response = await http
        .get(uri, headers: _headers(token))
        .timeout(const Duration(seconds: 8));
    final data = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && data is List) return data;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not load schedules'
          : 'Could not load schedules',
    );
  }

  Future<Map<String, dynamic>> updateSchedule(
    Map<String, dynamic> data,
    String token,
  ) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/schedules'),
          headers: _headers(token),
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 10));
    final body = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      body is Map<String, dynamic>
          ? body['error']?.toString() ?? 'Could not update schedule'
          : 'Could not update schedule',
    );
  }

  Future<Map<String, dynamic>> updateBusStatus(
    int busNumber,
    String status,
    String token,
  ) async {
    final response = await http
        .patch(
          Uri.parse('$baseUrl/buses/$busNumber'),
          headers: _headers(token),
          body: jsonEncode({'status': status}),
        )
        .timeout(const Duration(seconds: 10));

    final data = response.body.isNotEmpty
        ? _decodeJsonResponse(response)
        : <String, dynamic>{};
    if (response.statusCode == 200) {
      return data is Map<String, dynamic>
          ? data
          : <String, dynamic>{'data': data};
    }

    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'Failed to update bus status'
          : 'Failed to update bus status',
    );
  }

  Future<Map<String, dynamic>> addBus({
    required int busNumber,
    required String assignedHostel,
    required String driverName,
    required String driverPhone,
    required String pin,
    required String token,
    String? name,
    String? sourcePlace,
    String? destinationPlace,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/buses'),
          headers: _headers(token),
          body: jsonEncode({
            'busNumber': busNumber,
            if (name != null) 'name': name,
            'assignedHostel': assignedHostel,
            if (sourcePlace != null) 'sourcePlace': sourcePlace,
            if (destinationPlace != null) 'destinationPlace': destinationPlace,
            'driverName': driverName,
            'driverPhone': driverPhone,
            'pin': pin,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final data = _decodeJsonResponse(response);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }

    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'Failed to add bus'
          : 'Failed to add bus',
    );
  }

  Future<Map<String, dynamic>> updateBusDetails({
    required int busNumber,
    required String name,
    required String sourcePlace,
    required String destinationPlace,
    required String token,
  }) async {
    final response = await http
        .patch(
          Uri.parse('$baseUrl/buses/$busNumber'),
          headers: _headers(token),
          body: jsonEncode({
            'name': name,
            'sourcePlace': sourcePlace,
            'destinationPlace': destinationPlace,
          }),
        )
        .timeout(const Duration(seconds: 10));
    final data = _decodeJsonResponse(response);
    if (response.statusCode == 200 && data is Map<String, dynamic>) {
      return data;
    }
    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'Failed to update bus details'
          : 'Failed to update bus details',
    );
  }

  Future<Map<String, dynamic>> updateBusDriver({
    required int busNumber,
    required String driverName,
    required String driverPhone,
    required String token,
    String? pin,
  }) async {
    final response = await http
        .patch(
          Uri.parse('$baseUrl/buses/$busNumber/driver'),
          headers: _headers(token),
          body: jsonEncode({
            'driverName': driverName,
            'driverPhone': driverPhone,
            if (pin != null && pin.isNotEmpty) 'pin': pin,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final data = _decodeJsonResponse(response);
    if (response.statusCode == 200) {
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }

    throw Exception(
      data is Map<String, dynamic>
          ? data['error'] ?? 'Failed to update driver'
          : 'Failed to update driver',
    );
  }

  Future<List<dynamic>> getNotifications({
    String? hostel,
    String? token,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/notifications',
    ).replace(queryParameters: hostel == null ? null : {'hostel': hostel});
    final response = await http
        .get(uri, headers: _headers(token))
        .timeout(const Duration(seconds: 8));
    final data = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && data is List) return data;
    throw Exception(
      data is Map<String, dynamic>
          ? data['error']?.toString() ?? 'Could not load notifications'
          : 'Could not load notifications',
    );
  }

  Future<Map<String, dynamic>> sendNotification(
    Map<String, dynamic> data,
    String token,
  ) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/notifications/send'),
          headers: _headers(token),
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 10));
    final body = _tryDecodeJson(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      body is Map<String, dynamic>
          ? body['error']?.toString() ?? 'Could not send notification'
          : 'Could not send notification',
    );
  }
}
