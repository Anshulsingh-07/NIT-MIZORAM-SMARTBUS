import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'api_service.dart';
import 'notification_service.dart';

class BusService extends ChangeNotifier {
  List<BusModel> _buses = [];
  List<ScheduleModel> _schedules = [];
  bool _isLoading = false;
  bool _isWaking = false;
  String? _error;

  List<BusModel> get buses => _buses;
  List<ScheduleModel> get schedules => _schedules;
  bool get isLoading => _isLoading;
  bool get isWaking => _isWaking;
  String? get error => _error;

  Timer? _monitorTimer;
  Timer? _wakingTimer;
  final Set<String> _sentNotifications = {};

  List<BusModel> getBusesByHostel(String hostel) =>
      _buses.where((b) => b.assignedHostel == hostel).toList();

  BusModel? getBusByNumber(int number) {
    try {
      return _buses.firstWhere((b) => b.busNumber == number);
    } catch (e) {
      return null;
    }
  }

  int get runningBusCount => _buses.where((b) => b.status == 'running').length;
  int get maintenanceBusCount =>
      _buses.where((b) => b.status == 'maintenance').length;
  int get totalBusCount => _buses.length;

  Future<void> loadBuses(
    ApiService api, {
    String? hostel,
    String? token,
  }) async {
    if (_isLoading) return;
    _isLoading = true;
    _isWaking = false;
    _error = null;
    notifyListeners();
    _wakingTimer?.cancel();
    _wakingTimer = Timer(const Duration(seconds: 8), () {
      if (_isLoading) {
        _isWaking = true;
        notifyListeners();
      }
    });

    try {
      final data = await api.getBuses(hostel: hostel, token: token);
      _buses = data
          .map((b) => BusModel.fromJson(b as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _error = e.toString();
    } finally {
      _wakingTimer?.cancel();
      _wakingTimer = null;
      _isWaking = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _wakingTimer?.cancel();
    _monitorTimer?.cancel();
    super.dispose();
  }

  Future<void> loadSchedules(
    ApiService api, {
    String? hostel,
    String? token,
  }) async {
    try {
      final data = await api.getSchedules(hostel: hostel, token: token);
      _schedules = data
          .map((s) => ScheduleModel.fromJson(s as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('Schedule load error: $e');
    }
  }

  Future<bool> updateSchedule(
    ScheduleModel schedule,
    ApiService api,
    String token,
  ) async {
    try {
      await api.updateSchedule(schedule.toJson(), token);
      final idx = _schedules.indexWhere(
        (s) => s.busNumber == schedule.busNumber && s.date == schedule.date,
      );
      if (idx != -1) {
        _schedules[idx] = schedule;
      } else {
        _schedules.add(schedule);
      }
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateBusStatus(
    int busNumber,
    String status,
    ApiService api,
    String token,
  ) async {
    try {
      final response = await api.updateBusStatus(busNumber, status, token);
      final idx = _buses.indexWhere((b) => b.busNumber == busNumber);
      if (idx != -1) {
        final bus = _buses[idx];
        final updatedBus = response['data'] is Map<String, dynamic>
            ? response['data'] as Map<String, dynamic>
            : response;
        _buses[idx] = BusModel(
          busNumber: (updatedBus['busNumber'] ?? bus.busNumber) as int,
          assignedHostel: (updatedBus['assignedHostel'] ?? bus.assignedHostel)
              .toString(),
          status: (updatedBus['status'] ?? status).toString(),
          latitude: ((updatedBus['latitude'] ?? bus.latitude) as num)
              .toDouble(),
          longitude: ((updatedBus['longitude'] ?? bus.longitude) as num)
              .toDouble(),
          speed: ((updatedBus['speed'] ?? bus.speed) as num).toDouble(),
          isEnabled: updatedBus['isEnabled'] is bool
              ? updatedBus['isEnabled'] as bool
              : bus.isEnabled,
          driver: bus.driver,
          schedule: bus.schedule,
          route: (updatedBus['route'] ?? bus.route).toString(),
          lastUpdated: updatedBus['lastUpdated'] == null
              ? bus.lastUpdated
              : DateTime.tryParse(updatedBus['lastUpdated'].toString()) ??
                    bus.lastUpdated,
        );
        notifyListeners();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Start monitoring buses and send notifications when a bus nears a stop
  /// for the provided [user]. Notifications are sent only when
  /// the user's `hostelId` matches the bus's `assignedHostel`.
  void startArrivalMonitoring(
    UserModel user,
    NotificationService notificationService, {
    double thresholdKm = 0.15,
    Duration interval = const Duration(seconds: 15),
  }) {
    // stop any existing monitor
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(interval, (_) async {
      if (_buses.isEmpty) return;
      for (final bus in _buses) {
        try {
          // only consider relevant buses
          if (user.hostelId == null) continue;
          if (bus.assignedHostel != user.hostelId) continue;

          // Check distance to assigned hostel
          final distHostel = bus.distanceToHostel; // in km
          if (distHostel <= thresholdKm) {
            final key = '${bus.busNumber}-HOSTEL';
            if (!_sentNotifications.contains(key)) {
              _sentNotifications.add(key);
              final alert = NotificationModel(
                id: '${bus.busNumber}-HOSTEL-${DateTime.now().millisecondsSinceEpoch}',
                title: 'Bus ${bus.busNumber} arriving',
                message:
                    'Your bus ${bus.busNumber} is arriving near ${bus.assignedHostel}',
                type: 'arrival',
                busNumber: bus.busNumber,
                targetHostel: user.hostelId,
                sentAt: DateTime.now(),
              );
              notificationService.addLocalNotification(alert);
              unawaited(
                NotificationService.showLocalNotification(
                  title: alert.title,
                  message: alert.message,
                  busNumber: alert.busNumber,
                ),
              );
            }
          }

          // Check distance to MBSE gate
          final distMbse = bus.distanceToMBSE;
          if (distMbse <= thresholdKm) {
            final key = '${bus.busNumber}-MBSE';
            if (!_sentNotifications.contains(key)) {
              _sentNotifications.add(key);
              final alert = NotificationModel(
                id: '${bus.busNumber}-MBSE-${DateTime.now().millisecondsSinceEpoch}',
                title: 'Bus ${bus.busNumber} near MBSE',
                message:
                    'Bus ${bus.busNumber} (for ${bus.assignedHostel}) is near MBSE gate',
                type: 'arrival',
                busNumber: bus.busNumber,
                targetHostel: user.hostelId,
                sentAt: DateTime.now(),
              );
              notificationService.addLocalNotification(alert);
              unawaited(
                NotificationService.showLocalNotification(
                  title: alert.title,
                  message: alert.message,
                  busNumber: alert.busNumber,
                ),
              );
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('Arrival monitor error: $e');
        }
      }
    });
  }

  void stopArrivalMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _sentNotifications.clear();
  }

  String calculateETA(BusModel bus, double hostLat, double hostLng) {
    final dist = _haversine(bus.latitude, bus.longitude, hostLat, hostLng);
    if (bus.status != 'running') return 'Not running';
    final speed = bus.speed > 0 ? bus.speed : 30;
    final minutes = (dist / speed * 60).round();
    if (minutes < 2) return 'Arriving now';
    return '$minutes min';
  }

  double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _toRad(double deg) => deg * pi / 180;
}
