import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../auth/login_screen.dart';
import '../student/map_screen.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  StreamSubscription<Position>? _positionSubscription;
  Timer? _queueTimer;
  Timer? _clockTimer;
  final List<Map<String, dynamic>> _queue = [];
  Position? _position;
  Map<String, dynamic>? _lastFix;
  DateTime? _lastQueuedAt;
  DateTime? _lastSuccessfulSend;
  bool _sharing = false;
  bool _sending = false;
  bool _busy = false;
  bool _authExpired = false;
  String? _message;
  String? _queueKey;

  int get _busNumber => context.read<AuthService>().currentUser?.busNumber ?? 0;
  String get _tripKey => 'driver_trip_active_$_busNumber';

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreTrip());
  }

  Future<void> _restoreTrip() async {
    final prefs = await SharedPreferences.getInstance();
    _queueKey = 'driver_location_queue_$_busNumber';
    final lastFix = prefs.getString('driver_last_fix_$_busNumber');
    if (lastFix != null) {
      try {
        _lastFix = Map<String, dynamic>.from(jsonDecode(lastFix) as Map);
      } catch (_) {
        await prefs.remove('driver_last_fix_$_busNumber');
      }
    }
    final encoded = prefs.getString(_queueKey!);
    if (encoded != null) {
      try {
        final stored = jsonDecode(encoded);
        if (stored is List) {
          _queue.addAll(
            stored.whereType<Map>().map(
              (item) => Map<String, dynamic>.from(item),
            ),
          );
        }
      } catch (_) {
        await prefs.remove(_queueKey!);
      }
    }
    _queueTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _flushQueue(),
    );
    if (mounted) setState(() {});
    if (prefs.getBool(_tripKey) == true && mounted) {
      final resume = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Resume your trip?'),
          content: const Text(
            'A trip was active when Campus Bus Tracker last closed. Resume sharing this bus location?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('End trip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Resume'),
            ),
          ],
        ),
      );
      if (resume == true) {
        await _startTrip(showExplanation: false);
      } else {
        await prefs.setBool(_tripKey, false);
        await _queueIdleFix();
        await _flushQueue();
      }
    }
  }

  Future<bool> _requestPermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Location is turned off'),
            content: const Text(
              'Turn on location services, then start the trip again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  Geolocator.openLocationSettings();
                },
                child: const Text('Location settings'),
              ),
            ],
          ),
        );
      }
      return false;
    }

    var location = await Geolocator.checkPermission();
    if (location == LocationPermission.denied) {
      location = await Geolocator.requestPermission();
    }
    if (location == LocationPermission.deniedForever) {
      await _showSettingsDialog(
        'Location permission is blocked. Allow location access in app settings to share your bus position.',
      );
      return false;
    }
    if (location == LocationPermission.denied) return false;

    if (Platform.isAndroid || Platform.isIOS) {
      var always = await Permission.locationAlways.status;
      if (!always.isGranted) always = await Permission.locationAlways.request();
      if (!always.isGranted) {
        if (always.isPermanentlyDenied) {
          await _showSettingsDialog(
            'Allow location all the time so sharing can continue while your screen is locked.',
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Background location permission is needed during a driver trip.',
              ),
            ),
          );
        }
        return false;
      }
    }

    if (Platform.isAndroid) {
      var notification = await Permission.notification.status;
      if (!notification.isGranted) {
        notification = await Permission.notification.request();
      }
      if (!notification.isGranted) {
        await _showSettingsDialog(
          'Allow notifications so Android can show the persistent trip-sharing status.',
        );
        return false;
      }
    }
    return true;
  }

  Future<void> _showSettingsDialog(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission needed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _startTrip({bool showExplanation = true}) async {
    if (_busy || _sharing) return;
    if (showExplanation) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start location sharing?'),
          content: Text(
            'While this trip is active, Bus $_busNumber location is shared with campus bus tracker so students can follow it. Android will keep a persistent notification visible.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await _requestPermissions()) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_tripKey, true);
      await WakelockPlus.enable();
      final settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
              intervalDuration: const Duration(seconds: 2),
              foregroundNotificationConfig: ForegroundNotificationConfig(
                notificationTitle: 'Sharing Bus $_busNumber location',
                notificationText:
                    'Your trip is active. Tap End Trip when finished.',
                notificationChannelName: 'Bus trip location sharing',
                enableWakeLock: true,
                setOngoing: true,
              ),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            );
      _position = await Geolocator.getLastKnownPosition();
      _lastQueuedAt = null;
      _positionSubscription =
          Geolocator.getPositionStream(locationSettings: settings).listen(
            _onPosition,
            onError: (Object error) {
              if (mounted) setState(() => _message = 'GPS error: $error');
            },
          );
      if (mounted) {
        setState(() {
          _sharing = true;
          _message = null;
        });
      }
      await _flushQueue();
      _maybeShowBatteryTip();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not start location sharing: $error');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_tripKey, false);
      await WakelockPlus.disable();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _maybeShowBatteryTip() async {
    if (!Platform.isAndroid || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('driver_battery_tip_shown') == true) return;
    await prefs.setBool('driver_battery_tip_shown', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep sharing reliable'),
        content: const Text(
          'Some phones restrict background location to save battery. If updates stop with the screen locked, allow Campus Bus Tracker to run without battery optimization.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final status = await Permission.ignoreBatteryOptimizations
                  .request();
              if (!status.isGranted) await openAppSettings();
            },
            child: const Text('Battery settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _onPosition(Position position) async {
    if (position.accuracy > 50) {
      if (mounted) {
        setState(() {
          _position = position;
          _message =
              'Waiting for a better GPS fix (accuracy must be 50m or better).';
        });
      }
      return;
    }
    final now = DateTime.now();
    final elapsed = _lastQueuedAt == null
        ? 99.0
        : now.difference(_lastQueuedAt!).inMilliseconds / 1000;
    if (elapsed < 2.5) return;
    final previous = _position;
    final moved = previous == null
        ? 999.0
        : Geolocator.distanceBetween(
            previous.latitude,
            previous.longitude,
            position.latitude,
            position.longitude,
          );
    if (moved < 5 && elapsed < 12) {
      if (mounted) setState(() => _position = position);
      return;
    }
    _position = position;
    _lastQueuedAt = now;
    final fix = <String, dynamic>{
      'busNumber': _busNumber,
      'lat': position.latitude,
      'lng': position.longitude,
      'speed': position.speed.isFinite && position.speed > 0
          ? position.speed * 3.6
          : 0,
      'heading': position.heading.isFinite && position.heading >= 0
          ? position.heading
          : null,
      'accuracy': position.accuracy,
      'timestamp': position.timestamp.toUtc().toIso8601String(),
    };
    _lastFix = Map<String, dynamic>.from(fix);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_last_fix_$_busNumber', jsonEncode(_lastFix));
    await _enqueueFix(fix);
    await _flushQueue();
    if (mounted) setState(() => _message = null);
  }

  Future<void> _enqueueFix(Map<String, dynamic> fix) async {
    if (_queue.isNotEmpty &&
        fix['status'] == null &&
        _queue.last['status'] == 'idle') {
      _queue.removeLast();
    }
    _queue.add(fix);
    if (_queue.length > 200) _queue.removeAt(0);
    await _saveQueue();
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    _queueKey ??= 'driver_location_queue_$_busNumber';
    await prefs.setString(_queueKey!, jsonEncode(_queue));
  }

  Future<void> _flushQueue() async {
    if (_sending || _queue.isEmpty || _authExpired) return;
    _sending = true;
    try {
      final token = context.read<AuthService>().currentUser?.token;
      if (token == null) return;
      final api = context.read<ApiService>();
      while (_queue.isNotEmpty && mounted) {
        final status = await api.sendDriverLocation(_queue.first, token);
        if (status == 200) {
          _queue.removeAt(0);
          _lastSuccessfulSend = DateTime.now();
          await _saveQueue();
          if (mounted) setState(() {});
          continue;
        }
        if (status == 401) {
          await _handleExpiredSession();
        } else if (mounted) {
          setState(
            () => _message = status == 403
                ? 'Server rejected this bus assignment. Sign in again or contact a caretaker.'
                : 'Location update is queued and will retry when the connection returns.',
          );
        }
        break;
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Offline: ${_queue.length} location update(s) queued for retry.',
        );
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _handleExpiredSession() async {
    if (_authExpired || !mounted) return;
    _authExpired = true;
    await _stopSharing(markTripEnded: false);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Please sign in again'),
        content: Text(
          'Your session expired. ${_queue.length} queued location update(s) remain saved on this device.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await context.read<AuthService>().logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _endTrip() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _queueIdleFix();
    await _stopSharing(markTripEnded: true);
    await _flushQueue();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _queueIdleFix() async {
    Map<String, dynamic>? finalFix;
    final position = _position;
    if (position != null && position.accuracy <= 50) {
      finalFix = {
        'busNumber': _busNumber,
        'lat': position.latitude,
        'lng': position.longitude,
        'heading': position.heading,
        'accuracy': position.accuracy,
      };
    } else if (_lastFix != null) {
      finalFix = Map<String, dynamic>.from(_lastFix!);
    } else if (_queue.isNotEmpty) {
      finalFix = Map<String, dynamic>.from(_queue.last);
    }
    if (finalFix == null) return;
    finalFix.addAll({
      'speed': 0,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'status': 'idle',
    });
    await _enqueueFix(finalFix);
  }

  Future<void> _stopSharing({required bool markTripEnded}) async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    if (markTripEnded) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_tripKey, false);
    }
    await WakelockPlus.disable();
    if (mounted) setState(() => _sharing = false);
  }

  Future<void> _logout() async {
    if (_sharing) await _endTrip();
    if (!mounted) return;
    await context.read<AuthService>().logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _queueTimer?.cancel();
    _clockTimer?.cancel();
    if (!_sharing) WakelockPlus.disable();
    super.dispose();
  }

  String _lastSentLabel() {
    final sent = _lastSuccessfulSend;
    if (sent == null) return 'No location sent yet';
    final seconds = DateTime.now().difference(sent).inSeconds;
    return 'Last sent ${seconds}s ago';
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthService>().currentUser;
    final speed = _position?.speed.isFinite == true
        ? (_position!.speed * 3.6).clamp(0, 250)
        : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Trip'),
        actions: [
          IconButton(
            tooltip: 'Fleet map',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MapScreen()),
            ),
            icon: const Icon(Icons.map_outlined),
          ),
          IconButton(
            tooltip: 'Log out',
            onPressed: _busy ? null : _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.directions_bus)),
                title: Text('Bus ${user?.busNumber ?? '—'}'),
                subtitle: Text(user?.name ?? 'Driver'),
                trailing: const Text('Assigned'),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _sharing
                              ? Icons.wifi_tethering
                              : Icons.location_disabled,
                          color: _sharing ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _sharing ? 'Sharing location' : 'Trip not active',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(_lastSentLabel()),
                    const SizedBox(height: 8),
                    Text('Speed  ${speed.toStringAsFixed(1)} km/h'),
                    Text(
                      'GPS accuracy  ${_position?.accuracy.toStringAsFixed(0) ?? '—'} m',
                    ),
                    if (_queue.isNotEmpty)
                      Text('Queued updates  ${_queue.length}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 58,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _sharing
                      ? Colors.red.shade700
                      : Colors.green.shade700,
                ),
                onPressed: _busy
                    ? null
                    : (_sharing ? _endTrip : () => _startTrip()),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_sharing ? Icons.stop : Icons.play_arrow, size: 28),
                label: Text(
                  _busy
                      ? 'Please wait…'
                      : (_sharing ? 'End Trip' : 'Start Trip'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
