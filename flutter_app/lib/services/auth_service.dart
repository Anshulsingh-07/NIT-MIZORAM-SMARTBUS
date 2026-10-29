import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'api_service.dart';

enum AuthCheckResult { authenticated, unauthenticated, unavailable }

String _normalizeCaretakerLoginEmail(String email) {
  final normalizedEmail = email.trim().toLowerCase();
  final match = RegExp(
    r'^caretaker[-_](gh1|gh2|bh1|bh2|bh3|bh4)(?:@nitmz\.ac\.in)?$',
  ).firstMatch(normalizedEmail);
  if (match == null) return email.trim();
  return 'caretaker-${match.group(1)}@nitmz.ac.in';
}

class AuthService extends ChangeNotifier {
  AuthService({this.startupRetryDelay = const Duration(seconds: 2)});

  static const int _startupMaxAttempts = 3;
  static const Duration _startupFirstTimeout = Duration(seconds: 60);
  static const Duration _startupRetryTimeout = Duration(seconds: 15);

  final Duration startupRetryDelay;
  UserModel? _currentUser;
  bool _isLoading = false;
  String? _error;

  UserModel? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isLoggedIn => _currentUser != null;
  bool get isAdmin => _currentUser?.isAdmin ?? false;
  bool get isDriver => _currentUser?.isDriver ?? false;

  String _userFacingError(Object error) {
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    if (raw.isEmpty) {
      return 'Something went wrong. Please try again.';
    }
    final text = raw.toLowerCase();
    if (text.contains('<html') ||
        text.contains('<!doctype html') ||
        text.contains('formatexception') ||
        text.contains('unexpected server response') ||
        text.contains('invalid page')) {
      return 'Unexpected server response — please try again.';
    }
    if (text.contains('invalid email') ||
        text.contains('invalid credentials') ||
        text.contains('incorrect pin') ||
        text.contains('login failed') ||
        text.contains('invalid password') ||
        text.contains('not recognized')) {
      return 'Invalid email or password';
    }
    return raw;
  }

  Future<AuthCheckResult> checkAuthState(ApiService api) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final email = prefs.getString('email');

    if (token == null || token.isEmpty) {
      _currentUser = null;
      _error = null;
      notifyListeners();
      return AuthCheckResult.unauthenticated;
    }

    if (token != null && email == null && prefs.getString('role') == 'driver') {
      final validation = await _validateSavedSession(
        (timeout) => api.getDriverCurrentUser(token, timeout: timeout),
      );
      if (validation.result != AuthCheckResult.authenticated) {
        if (validation.result == AuthCheckResult.unauthenticated) {
          await _clearSavedCredentials(prefs);
        }
        notifyListeners();
        return validation.result;
      }

      _currentUser = UserModel.fromJson({...validation.user!, 'token': token});
      await prefs.setString('name', _currentUser!.name);
      await prefs.setString('phone', _currentUser!.phone ?? '');
      if (_currentUser!.busNumber != null) {
        await prefs.setInt('busNumber', _currentUser!.busNumber!);
      }
      _error = null;
      notifyListeners();
      return AuthCheckResult.authenticated;
    }

    if (email == null) {
      _currentUser = null;
      await _clearSavedCredentials(prefs);
      notifyListeners();
      return AuthCheckResult.unauthenticated;
    }

    final name = prefs.getString('name');
    final role = prefs.getString('role');
    final hostelId = prefs.getString('hostelId');
    final userId = prefs.getString('userId');

    final validation = await _validateSavedSession(
      (timeout) => api.getCurrentUser(token, timeout: timeout),
    );
    if (validation.result != AuthCheckResult.authenticated) {
      if (validation.result == AuthCheckResult.unauthenticated) {
        await _clearSavedCredentials(prefs);
      }
      notifyListeners();
      return validation.result;
    }

    final remoteUser = validation.user!;
    _currentUser = UserModel(
      id: (remoteUser['id'] ?? userId ?? '').toString(),
      name: (remoteUser['name'] ?? name ?? '').toString(),
      email: (remoteUser['email'] ?? email).toString(),
      role: (remoteUser['role'] ?? role ?? 'student').toString(),
      hostelId: remoteUser['hostelId']?.toString() ?? hostelId,
      mustChangePassword: remoteUser['mustChangePassword'] == true,
      token: token,
    );

    if (_currentUser!.email.isNotEmpty) {
      await prefs.setString('email', _currentUser!.email);
    }
    await prefs.setString('name', _currentUser!.name);
    await prefs.setString('role', _currentUser!.role);
    await prefs.setString('userId', _currentUser!.id);
    if (_currentUser!.hostelId != null && _currentUser!.hostelId!.isNotEmpty) {
      await prefs.setString('hostelId', _currentUser!.hostelId!);
    }
    _error = null;
    notifyListeners();
    return AuthCheckResult.authenticated;
  }

  Future<_SessionValidation> _validateSavedSession(
    Future<Map<String, dynamic>> Function(Duration timeout) request,
  ) async {
    _error = null;
    Object? lastError;
    for (var attempt = 0; attempt < _startupMaxAttempts; attempt++) {
      final timeout = attempt == 0
          ? _startupFirstTimeout
          : _startupRetryTimeout;
      try {
        final user = await request(timeout);
        return _SessionValidation(AuthCheckResult.authenticated, user: user);
      } catch (error) {
        lastError = error;
        if (_isInvalidSavedSession(error)) {
          _currentUser = null;
          return const _SessionValidation(AuthCheckResult.unauthenticated);
        }

        final isTransient = _isTransientAuthFailure(error);
        if (!isTransient || attempt == _startupMaxAttempts - 1) break;
        await Future<void>.delayed(startupRetryDelay);
      }
    }

    _currentUser = null;
    _error = _isTransientAuthFailure(lastError)
        ? 'Server is waking up, please try again.'
        : 'Could not verify your session. Please try again.';
    return const _SessionValidation(AuthCheckResult.unavailable);
  }

  bool _isInvalidSavedSession(Object error) {
    if (error is! ApiResponseException) return false;
    if (error.statusCode == 401) return true;
    if (error.statusCode != 403) return false;

    final code = error.code?.toUpperCase();
    if (code == 'AUTHENTICATION_REQUIRED' ||
        code == 'INVALID_SESSION' ||
        code == 'SESSION_EXPIRED') {
      return true;
    }
    return RegExp(
      r'\b(invalid|expired)\b.*\b(session|token)\b|\b(session|token)\b.*\b(invalid|expired)\b',
      caseSensitive: false,
    ).hasMatch(error.message);
  }

  bool _isTransientAuthFailure(Object? error) {
    if (error is TimeoutException || error is http.ClientException) return true;
    // Keep SocketException support without importing dart:io into Flutter web.
    if (error?.runtimeType.toString() == 'SocketException') return true;
    return error is ApiResponseException && error.statusCode >= 500;
  }

  Future<void> _clearSavedCredentials(SharedPreferences prefs) async {
    _currentUser = null;
    _error = null;
    for (final key in [
      'token',
      'email',
      'phone',
      'busNumber',
      'name',
      'role',
      'userId',
      'hostelId',
    ]) {
      await prefs.remove(key);
    }
  }

  Future<bool> login(String email, String password, ApiService api) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final data = await api.login(
        _normalizeCaretakerLoginEmail(email),
        password,
      );
      ApiService.cancelBusStream();
      final userJson = data['user'] as Map<String, dynamic>;
      userJson['token'] = data['token'];
      _currentUser = UserModel.fromJson(userJson);
      _currentUser!.token = data['token'];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token']);
      await prefs.setString('email', _currentUser!.email);
      await prefs.setString('name', _currentUser!.name);
      await prefs.setString('role', _currentUser!.role);
      await prefs.setString('userId', _currentUser!.id);
      await prefs.remove('phone');
      await prefs.remove('busNumber');
      if (_currentUser!.hostelId != null) {
        await prefs.setString('hostelId', _currentUser!.hostelId!);
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _userFacingError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> driverLogin(String phone, String pin, ApiService api) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final data = await api.driverLogin(phone, pin);
      final userJson = Map<String, dynamic>.from(data['user'] as Map);
      userJson['token'] = data['token'];
      _currentUser = UserModel.fromJson(userJson);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token'].toString());
      await prefs.remove('email');
      await prefs.remove('hostelId');
      await prefs.setString('name', _currentUser!.name);
      await prefs.setString('role', 'driver');
      await prefs.setString('phone', _currentUser!.phone ?? phone);
      await prefs.setString('userId', _currentUser!.id);
      if (_currentUser!.busNumber != null) {
        await prefs.setInt('busNumber', _currentUser!.busNumber!);
      }
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _userFacingError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(
    String name,
    String email,
    String mobile,
    String password,
    String confirmPassword,
    String hostelId,
    ApiService api,
  ) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final data = await api.register(
        name,
        email,
        mobile,
        password,
        confirmPassword,
        hostelId,
      );
      final userJson = data['user'] as Map<String, dynamic>;
      userJson['token'] = data['token'];
      _currentUser = UserModel.fromJson(userJson);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token']);
      await prefs.setString('email', _currentUser!.email);
      await prefs.setString('name', _currentUser!.name);
      await prefs.setString('role', _currentUser!.role);
      await prefs.setString('userId', _currentUser!.id);
      await prefs.remove('phone');
      await prefs.remove('busNumber');
      if (_currentUser!.hostelId != null) {
        await prefs.setString('hostelId', _currentUser!.hostelId!);
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> changePassword(
    String currentPassword,
    String newPassword,
    ApiService api,
  ) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final token = _currentUser?.token;
      if (token == null || token.isEmpty) {
        throw Exception('Sign in again to change your password');
      }
      await api.changePassword(token, currentPassword, newPassword);
      _currentUser!.mustChangePassword = false;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void setError(String message) {
    _error = message;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> logout() async {
    final token = _currentUser?.token;
    ApiService.cancelBusStream(token);
    _currentUser = null;
    notifyListeners();
    if (token != null) {
      try {
        await ApiService().logout(token);
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      'token',
      'email',
      'phone',
      'name',
      'role',
      'userId',
      'hostelId',
      'busNumber',
    ]) {
      await prefs.remove(key);
    }
  }

  Future<bool> expireSession(String token) async {
    if (_currentUser?.token != token) return false;
    ApiService.cancelBusStream(token);
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      'token',
      'email',
      'phone',
      'name',
      'role',
      'userId',
      'hostelId',
      'busNumber',
    ]) {
      await prefs.remove(key);
    }
    notifyListeners();
    return true;
  }
}

class _SessionValidation {
  const _SessionValidation(this.result, {this.user});

  final AuthCheckResult result;
  final Map<String, dynamic>? user;
}
