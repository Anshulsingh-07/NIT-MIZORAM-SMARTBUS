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
}
