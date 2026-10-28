import 'dart:math';
import 'package:flutter/material.dart';

class BusModel {
  final int busNumber;
  final String assignedHostel;
  final String status;
  final double latitude;
  final double longitude;
  final double speed;
  final bool isEnabled;
  final DriverModel? driver;
  final ScheduleModel? schedule;
  final String route;
  final DateTime? lastUpdated;

  static const Map<String, List<double>> _knownHostelCoordinates = {
    'BH1': [23.792917, 92.727789],
    'BH2': [23.794311, 92.728146],
    'BH3': [23.767378, 92.737712],
    'BH4': [23.769835, 92.737959],
    'GH1': [23.775578, 92.731044],
    'GH2': [23.784357, 92.728380],
    'NIT': [23.7278, 92.7179],
  };

  // MBSE gate coordinates used by the campus route model.
  static const List<double> _mbseCoordinates = [23.7573, 92.7288];

  BusModel({
    required this.busNumber,
    required this.assignedHostel,
    required this.status,
    required this.latitude,
    required this.longitude,
    this.speed = 0,
    this.isEnabled = true,
    this.driver,
    this.schedule,
    this.route = 'Hostel ↔ MBSE',
    this.lastUpdated,
  });

  factory BusModel.fromJson(Map<String, dynamic> json) {
    return BusModel(
      busNumber: json['busNumber'] ?? 0,
      assignedHostel: json['assignedHostel'] ?? '',
      status: json['status'] ?? 'idle',
      latitude: (json['latitude'] ?? 23.7271).toDouble(),
      longitude: (json['longitude'] ?? 92.7176).toDouble(),
      speed: (json['speed'] ?? 0).toDouble(),
      isEnabled: json['isEnabled'] ?? true,
      driver: json['driver'] != null
          ? DriverModel.fromJson(json['driver'])
          : null,
      schedule: json['schedule'] != null
          ? ScheduleModel.fromJson(json['schedule'])
          : null,
      route: json['route'] ?? 'Hostel ↔ MBSE',
      lastUpdated: json['lastUpdated'] == null
          ? null
          : DateTime.tryParse(json['lastUpdated'].toString()),
    );
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

  List<double> get _assignedHostelCoords {
    return _knownHostelCoordinates[assignedHostel] ??
        _knownHostelCoordinates['BH1']!;
  }

  double get distanceToHostel {
    final coords = _assignedHostelCoords;
    return _haversine(latitude, longitude, coords[0], coords[1]);
  }

  double get distanceToMBSE {
    return _haversine(
      latitude,
      longitude,
      _mbseCoordinates[0],
      _mbseCoordinates[1],
    );
  }

  bool get isHeadingToMBSE {
    if (assignedHostel.startsWith('GH')) {
      return false;
    }
    return distanceToMBSE <= distanceToHostel;
  }

  String get destinationLabel => isHeadingToMBSE ? 'MBSE' : assignedHostel;

  String get hostelDisplayName {
    final hostel = HostelModel.allHostels.firstWhere(
      (h) => h.id == assignedHostel,
      orElse: () => const HostelModel(
        id: 'BH1',
        name: 'BH1',
        type: 'Boys',
        fullName: "Boys' Hostel 1",
      ),
    );
    return hostel.fullName;
  }

  String get routeStartLabel =>
      isHeadingToMBSE ? hostelDisplayName : 'MBSE Main Gate';

  String get routeEndLabel =>
      isHeadingToMBSE ? 'MBSE Main Gate' : hostelDisplayName;

  String get routeStartShortLabel => isHeadingToMBSE ? assignedHostel : 'MBSE';

  String get routeEndShortLabel => isHeadingToMBSE ? 'MBSE' : assignedHostel;

  List<RoutePoint> get routePoints {
    final start = RoutePoint(latitude: latitude, longitude: longitude);
    final destinationCoords = isHeadingToMBSE
        ? _mbseCoordinates
        : _assignedHostelCoords;
    final end = RoutePoint(
      latitude: destinationCoords[0],
      longitude: destinationCoords[1],
    );
    final points = <RoutePoint>[start];

    for (int step = 1; step <= 8; step++) {
      final t = step / 8;
      final lat = start.latitude + (end.latitude - start.latitude) * t;
      final lng = start.longitude + (end.longitude - start.longitude) * t;
      points.add(RoutePoint(latitude: lat, longitude: lng));
    }

    return points;
  }

  String get etaToDestination {
    final distanceKm = isHeadingToMBSE ? distanceToMBSE : distanceToHostel;
    final effectiveSpeed = speed > 3 ? speed : 25;
    final minutes = (distanceKm / effectiveSpeed * 60).round();
    if (minutes <= 1) return 'Arriving now';
    return '$minutes min';
  }

  String get etaSummary => 'To $destinationLabel • $etaToDestination';

  Color get statusColor {
    switch (status) {
      case 'running':
        return const Color(0xFF4CAF50);
      case 'maintenance':
        return const Color(0xFFFF5722);
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  String get statusLabel {
    switch (status) {
      case 'running':
        return 'Running';
      case 'maintenance':
        return 'Maintenance';
      default:
        return 'Idle';
    }
  }
}

class DriverModel {
  final String id;
  final String name;
  final String phone;
  final int busNumber;
  final bool isActive;

  DriverModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.busNumber,
    this.isActive = true,
  });

  factory DriverModel.fromJson(Map<String, dynamic> json) {
    return DriverModel(
      id: json['_id'] ?? '',
      name: json['name'] ?? '',
      phone: json['phone'] ?? '',
      busNumber: json['busNumber'] ?? 0,
      isActive: json['isActive'] ?? true,
    );
  }
}

class RoutePoint {
  final double latitude;
  final double longitude;

  const RoutePoint({required this.latitude, required this.longitude});
}

class ScheduleModel {
  final String id;
  final int busNumber;
  final String date;
  final String fromHostelTime;
  final String fromMBSETime;
  final String specialNote;
  final String updatedBy;

  ScheduleModel({
    required this.id,
    required this.busNumber,
    required this.date,
    required this.fromHostelTime,
    required this.fromMBSETime,
    this.specialNote = '',
    this.updatedBy = '',
  });

  factory ScheduleModel.fromJson(Map<String, dynamic> json) {
    return ScheduleModel(
      id: json['_id'] ?? '',
      busNumber: json['busNumber'] ?? 0,
      date: json['date'] ?? '',
      fromHostelTime: json['fromHostelTime'] ?? '',
      fromMBSETime: json['fromMBSETime'] ?? '',
      specialNote: json['specialNote'] ?? '',
      updatedBy: json['updatedBy'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'busNumber': busNumber,
    'date': date,
    'fromHostelTime': fromHostelTime,
    'fromMBSETime': fromMBSETime,
    'specialNote': specialNote,
  };
}

class NotificationModel {
  final String id;
  final String title;
  final String message;
  final String type;
  final int? busNumber;
  final String? targetHostel;
  final DateTime sentAt;
  bool isRead;

  NotificationModel({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    this.busNumber,
    this.targetHostel,
    required this.sentAt,
    this.isRead = false,
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      id: json['_id'] ?? '',
      title: json['title'] ?? '',
      message: json['message'] ?? '',
      type: json['type'] ?? 'general',
      busNumber: json['busNumber'],
      targetHostel: json['targetHostel'],
      sentAt: json['sentAt'] != null
          ? DateTime.parse(json['sentAt'])
          : DateTime.now(),
      isRead: json['isRead'] ?? false,
    );
  }

  IconData get typeIcon {
    switch (type) {
      case 'departure':
        return Icons.directions_bus;
      case 'arrival':
        return Icons.location_on;
      case 'delay':
        return Icons.access_time;
      case 'emergency':
        return Icons.warning;
      default:
        return Icons.notifications;
    }
  }

  Color get typeColor {
    switch (type) {
      case 'departure':
        return const Color(0xFF1565C0);
      case 'arrival':
        return const Color(0xFF4CAF50);
      case 'delay':
        return const Color(0xFFFF9800);
      case 'emergency':
        return const Color(0xFFFF5722);
      default:
        return const Color(0xFF9C27B0);
    }
  }
}

class UserModel {
  final String id;
  final String name;
  final String email;
  final String role;
  final String? hostelId;
  final String? phone;
  final int? busNumber;
  bool mustChangePassword;
  String? token;

  UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.hostelId,
    this.phone,
    this.busNumber,
    this.mustChangePassword = false,
    this.token,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] ?? json['_id'] ?? '',
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      role: json['role'] ?? 'student',
      hostelId: json['hostelId'],
      phone: json['phone']?.toString(),
      busNumber: (json['busNumber'] as num?)?.toInt(),
      mustChangePassword: json['mustChangePassword'] == true,
      token: json['token'],
    );
  }

  bool get isAdmin => role == 'admin' || role == 'caretaker';
  bool get isDriver => role == 'driver';
}

class HostelModel {
  final String id;
  final String name;
  final String type;
  final String fullName;

  const HostelModel({
    required this.id,
    required this.name,
    required this.type,
    required this.fullName,
  });

  static const List<HostelModel> allHostels = [
    HostelModel(
      id: 'GH1',
      name: 'GH1',
      type: 'Girls',
      fullName: "Girls' Hostel 1",
    ),
    HostelModel(
      id: 'GH2',
      name: 'GH2',
      type: 'Girls',
      fullName: "Girls' Hostel 2",
    ),
    HostelModel(
      id: 'BH1',
      name: 'BH1',
      type: 'Boys',
      fullName: "Boys' Hostel 1",
    ),
    HostelModel(
      id: 'BH2',
      name: 'BH2',
      type: 'Boys',
      fullName: "Boys' Hostel 2",
    ),
    HostelModel(
      id: 'BH3',
      name: 'BH3',
      type: 'Boys',
      fullName: "Boys' Hostel 3",
    ),
    HostelModel(
      id: 'BH4',
      name: 'BH4',
      type: 'Boys',
      fullName: "Boys' Hostel 4",
    ),
  ];
}
