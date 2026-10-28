import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'api_service.dart';

String _normalizeCaretakerLoginEmail(String email) {
  final normalizedEmail = email.trim().toLowerCase();
  final match = RegExp(
    r'^caretaker[-_](gh1|gh2|bh1|bh2|bh3|bh4)(?:@nitmz\.ac\.in)?$',
  ).firstMatch(normalizedEmail);
  if (match == null) return email.trim();
  return 'caretaker-${match.group(1)}@nitmz.ac.in';
}

class AuthService extends ChangeNotifier {
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

  Future<void> checkAuthState(ApiService api) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final email = prefs.getString('email');
    if (token != null && email == null && prefs.getString('role') == 'driver') {
      try {
        final remoteUser = await api.getDriverCurrentUser(token);
        _currentUser = UserModel.fromJson({...remoteUser, 'token': token});
        await prefs.setString('name', _currentUser!.name);
        await prefs.setString('phone', _currentUser!.phone ?? '');
        if (_currentUser!.busNumber != null) {
          await prefs.setInt('busNumber', _currentUser!.busNumber!);
        }
      } catch (_) {
        _currentUser = null;
        for (final key in [
          'token',
          'phone',
          'busNumber',
          'name',
          'role',
          'userId',
        ]) {
          await prefs.remove(key);
        }
      }
      notifyListeners();
      return;
    }
    if (token != null && email == null) {
      for (final key in [
        'token',
        'phone',
        'busNumber',
        'name',
        'role',
        'userId',
        'hostelId',
      ]) {
        await prefs.remove(key);
      }
      notifyListeners();
      return;
    }
    final name = prefs.getString('name');
    final role = prefs.getString('role');
    final hostelId = prefs.getString('hostelId');
    final userId = prefs.getString('userId');

    if (token != null && email != null) {
      try {
        final remoteUser = await api.getCurrentUser(token);
        _currentUser = UserModel(
          id: (remoteUser['id'] ?? userId ?? '').toString(),
          name: (remoteUser['name'] ?? name ?? '').toString(),
          email: (remoteUser['email'] ?? email ?? '').toString(),
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
        if (_currentUser!.hostelId != null &&
            _currentUser!.hostelId!.isNotEmpty) {
          await prefs.setString('hostelId', _currentUser!.hostelId!);
        }
      } catch (_) {
        _currentUser = null;
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

      notifyListeners();
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
    String mobileVerificationToken,
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
        mobileVerificationToken,
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
