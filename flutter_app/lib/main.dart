import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/app_config.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/bus_service.dart';
import 'services/notification_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/splash_screen.dart';

final GlobalKey<NavigatorState> _appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      unawaited(ApiService().checkHealthAtStartup());
      if (AppConfig.supabaseUrl.isNotEmpty &&
          AppConfig.supabasePublishableKey.isNotEmpty) {
        await Supabase.initialize(
          url: AppConfig.supabaseUrl,
          publishableKey: AppConfig.supabasePublishableKey,
        );
      }

      // Global error handling to surface uncaught errors while debugging.
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        // ignore: avoid_print
        print('FlutterError caught: ${details.exceptionAsString()}');
        if (details.stack != null) {
          // ignore: avoid_print
          print(details.stack);
        }
      };

      // Replace the default red error screen with a gentler placeholder so the
      // app remains usable while we log errors for debugging.
      ErrorWidget.builder = (FlutterErrorDetails details) {
        // ignore: avoid_print
        print('ErrorWidget triggered: ${details.exceptionAsString()}');
        return Material(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'UI error occurred',
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  details.exceptionAsString(),
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      };

      await NotificationService.initialize();
      runApp(const CampusBusTrackerApp());
    },
    (error, stack) {
      // ignore: avoid_print
      print('Uncaught zone error: $error');
      // ignore: avoid_print
      print(stack);
    },
  );
}

class CampusBusTrackerApp extends StatefulWidget {
  const CampusBusTrackerApp({super.key});

  @override
  State<CampusBusTrackerApp> createState() => _CampusBusTrackerAppState();
}

class _CampusBusTrackerAppState extends State<CampusBusTrackerApp> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _linkSubscription = _appLinks.uriLinkStream.listen(_handleAppLink);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final initialLink = await _appLinks.getInitialLink();
        if (initialLink != null) _handleAppLink(initialLink);
      } catch (_) {}
    });
  }

  void _handleAppLink(Uri uri) {
    if (uri.scheme != 'smartbus' ||
        uri.host != 'login' ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return;
    }
    _appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => BusService()),
        ChangeNotifierProvider(create: (_) => NotificationService()),
        Provider(create: (_) => ApiService()),
      ],
      child: MaterialApp(
        navigatorKey: _appNavigatorKey,
        title: 'Campus Bus Tracker',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            primary: const Color(0xFF1565C0),
            secondary: const Color(0xFF42A5F5),
            surface: const Color(0xFFF5F7FA),
          ),
          fontFamily: 'Roboto',
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1565C0),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: true,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 4,
            shadowColor: Colors.black12,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        home: const SplashScreen(),
      ),
    );
  }
}
