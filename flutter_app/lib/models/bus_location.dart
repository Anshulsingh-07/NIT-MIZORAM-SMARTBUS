class BusLocation {
  final String busId;
  final String deviceId;
  final String assignedHostel;
  final double lat;
  final double lng;
  final double speed;
  final double heading;
  final double accuracy;
  final String status;
  final int? etaSeconds;
  final int? etaMeters;
  final String? etaLabel;
  final DateTime timestamp;

  const BusLocation({
    required this.busId,
    required this.deviceId,
    this.assignedHostel = '',
    required this.lat,
    required this.lng,
    required this.speed,
    this.heading = 0,
    required this.accuracy,
    required this.status,
    required this.timestamp,
    this.etaSeconds,
    this.etaMeters,
    this.etaLabel,
  });

  factory BusLocation.fromJson(Map<String, dynamic> json) {
    double toDouble(dynamic value, double fallback) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? fallback;
      return fallback;
    }

    DateTime parseTimestamp(dynamic value) {
      if (value is String) {
        return DateTime.tryParse(value) ?? DateTime.now();
      }
      return DateTime.now();
    }

    return BusLocation(
      busId: (json['busId'] ?? json['bus_id'] ?? json['busNumber'] ?? 'Bus-1')
          .toString(),
      deviceId: (json['deviceId'] ?? json['device_id'] ?? 'device-1')
          .toString(),
      assignedHostel:
          (json['assignedHostel'] ??
                  json['assigned_hostel'] ??
                  json['hostel'] ??
                  '')
              .toString(),
      lat: toDouble(json['lat'] ?? json['latitude'], 23.7271),
      lng: toDouble(json['lng'] ?? json['longitude'], 92.7176),
      speed: toDouble(json['speed'], 0),
      heading: toDouble(json['heading'], 0),
      accuracy: toDouble(json['accuracy'] ?? json['hdop'], 1.0),
      status: (json['status'] ?? 'idle').toString(),
      timestamp: parseTimestamp(
        json['timestamp'] ?? json['ts'] ?? json['received_at'],
      ),
      etaSeconds: (json['eta_seconds'] is num)
          ? (json['eta_seconds'] as num).toInt()
          : (json['eta'] is num ? (json['eta'] as num).toInt() : null),
      etaMeters: (json['eta_meters'] is num)
          ? (json['eta_meters'] as num).toInt()
          : null,
      etaLabel: (json['eta_label'] ?? json['eta_text'] ?? json['eta']) is String
          ? (json['eta_label'] ?? json['eta_text'] ?? json['eta'])?.toString()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'busId': busId,
      'deviceId': deviceId,
      'assignedHostel': assignedHostel,
      'lat': lat,
      'lng': lng,
      'speed': speed,
      'heading': heading,
      'accuracy': accuracy,
      'status': status,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
