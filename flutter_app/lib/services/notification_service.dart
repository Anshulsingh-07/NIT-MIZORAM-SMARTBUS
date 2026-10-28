import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/models.dart';
import 'api_service.dart';

class NotificationService extends ChangeNotifier {
  static final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final Set<String> _sentDepartureAlerts = <String>{};
  Timer? _departureMonitor;

  List<NotificationModel> _notifications = [];
  bool _isLoading = false;

  List<NotificationModel> get notifications => _notifications;
  bool get isLoading => _isLoading;
  int get unreadCount => _notifications.where((n) => !n.isRead).length;

  static Future<void> initialize() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _localNotificationsPlugin.initialize(initSettings);
    await _localNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  static Future<void> showLocalNotification({
    required String title,
    required String message,
    int? busNumber,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'campus_bus_departure',
          'Bus departure alerts',
          channelDescription: 'Alerts when your hostel bus is about to leave.',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'Campus bus alert',
        );
    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    final id = busNumber ?? DateTime.now().millisecondsSinceEpoch;
    await _localNotificationsPlugin.show(id, title, message, details);
  }

  static NotificationModel? buildDepartureAlert({
    required BusModel bus,
    required String hostelId,
    DateTime? now,
  }) {
    if (hostelId.isEmpty) return null;
    if (bus.assignedHostel != hostelId) return null;
    if (bus.status != 'running') return null;
    if (bus.schedule == null) return null;

    final current = now ?? DateTime.now();
    final candidates = <_DepartureCandidate>[];

    final hostelDeparture = _parseScheduleTime(
      bus.schedule!.fromHostelTime,
      current,
    );
    if (hostelDeparture != null) {
      candidates.add(
        _DepartureCandidate(
          departureTime: hostelDeparture,
          sourceLabel: bus.assignedHostel,
          direction: 'Hostel → MBSE',
        ),
      );
    }

    final mbseDeparture = _parseScheduleTime(
      bus.schedule!.fromMBSETime,
      current,
    );
    if (mbseDeparture != null) {
      candidates.add(
        _DepartureCandidate(
          departureTime: mbseDeparture,
          sourceLabel: 'MBSE',
          direction: 'MBSE → ${bus.assignedHostel}',
        ),
      );
    }

    for (final candidate in candidates) {
      final diffMinutes = candidate.departureTime.difference(current).inMinutes;
      if (diffMinutes >= 0 && diffMinutes <= 2) {
        final message = diffMinutes == 0
            ? 'Bus ${bus.busNumber} is leaving now from ${candidate.sourceLabel}. Please come fast!'
            : 'Bus ${bus.busNumber} is leaving from ${candidate.sourceLabel} in $diffMinutes minute${diffMinutes == 1 ? '' : 's'}. Please come fast!';

        return NotificationModel(
          id: '${bus.busNumber}-${candidate.departureTime.millisecondsSinceEpoch}',
          title: 'Bus ${bus.busNumber} leaving soon',
          message: message,
          type: 'departure',
          busNumber: bus.busNumber,
          targetHostel: hostelId,
          sentAt: current,
          isRead: false,
        );
      }
    }

    return null;
  }

  void checkDepartureAlerts({
    required String hostelId,
    required List<BusModel> buses,
    DateTime? now,
  }) {
    if (hostelId.isEmpty) return;
    final current = now ?? DateTime.now();
    for (final bus in buses) {
      final alert = buildDepartureAlert(
        bus: bus,
        hostelId: hostelId,
        now: current,
      );
      if (alert == null) continue;

      final key =
          '${bus.busNumber}-${alert.sentAt.year}-${alert.sentAt.month}-${alert.sentAt.day}-${alert.sentAt.hour}-${alert.sentAt.minute}';
      if (_sentDepartureAlerts.contains(key)) continue;

      _sentDepartureAlerts.add(key);
      addLocalNotification(alert);
      unawaited(
        showLocalNotification(
          title: alert.title,
          message: alert.message,
          busNumber: bus.busNumber,
        ),
      );
      notifyListeners();
    }
  }

  void startDepartureMonitoring({
    required String hostelId,
    required List<BusModel> buses,
  }) {
    _departureMonitor?.cancel();
    _departureMonitor = Timer.periodic(const Duration(seconds: 30), (_) {
      checkDepartureAlerts(hostelId: hostelId, buses: buses);
    });
    checkDepartureAlerts(hostelId: hostelId, buses: buses);
  }

  void stopDepartureMonitoring() {
    _departureMonitor?.cancel();
    _departureMonitor = null;
  }

  Future<void> loadNotifications(
    ApiService api, {
    String? hostel,
    String? token,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await api.getNotifications(hostel: hostel, token: token);
      _notifications = data
          .map((n) => NotificationModel.fromJson(n as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('Notification load error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> sendNotification({
    required String title,
    required String message,
    required String type,
    int? busNumber,
    String? targetHostel,
    required ApiService api,
    required String token,
  }) async {
    try {
      final data = await api.sendNotification({
        'title': title,
        'message': message,
        'type': type,
        'busNumber': busNumber,
        'targetHostel': targetHostel,
      }, token);

      _notifications.insert(0, NotificationModel.fromJson(data));
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  void markAsRead(String id) {
    final idx = _notifications.indexWhere((n) => n.id == id);
    if (idx != -1) {
      _notifications[idx].isRead = true;
      notifyListeners();
    }
  }

  void markAllAsRead() {
    for (var n in _notifications) {
      n.isRead = true;
    }
    notifyListeners();
  }

  void addLocalNotification(NotificationModel notification) {
    _notifications.insert(0, notification);
    notifyListeners();
  }

  static DateTime? _parseScheduleTime(String rawTime, DateTime referenceDate) {
    final value = rawTime.trim();
    if (value.isEmpty) return null;

    final match = RegExp(
      r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2) ?? '0');
    final period = match.group(3)?.toLowerCase();

    if (period == 'pm' && hour != 12) hour += 12;
    if (period == 'am' && hour == 12) hour = 0;

    return DateTime(
      referenceDate.year,
      referenceDate.month,
      referenceDate.day,
      hour,
      minute,
    );
  }
}

class _DepartureCandidate {
  final DateTime departureTime;
  final String sourceLabel;
  final String direction;

  const _DepartureCandidate({
    required this.departureTime,
    required this.sourceLabel,
    required this.direction,
  });
}
