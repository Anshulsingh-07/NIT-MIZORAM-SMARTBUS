import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:campus_bus_tracker/services/api_service.dart';
import 'package:campus_bus_tracker/services/auth_service.dart';
import 'package:campus_bus_tracker/screens/auth/login_screen.dart';

void main() {
  testWidgets('registration form has optional mobile and no OTP step', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthService()),
          Provider(create: (_) => ApiService()),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final registerToggle = find.text("Don't have an account? Register");
    await tester.ensureVisible(registerToggle);
    await tester.tap(registerToggle);
    await tester.pumpAndSettle();

    expect(find.text('Mobile Number (optional)'), findsOneWidget);
    expect(
      find.text('Enter an Indian number; format +91XXXXXXXXXX'),
      findsOneWidget,
    );
    expect(find.text('Verify mobile number'), findsNothing);
    expect(find.text('Confirm code'), findsNothing);
    expect(find.text('Six-digit verification code'), findsNothing);
    expect(find.text('Register'), findsWidgets);
  });
}
