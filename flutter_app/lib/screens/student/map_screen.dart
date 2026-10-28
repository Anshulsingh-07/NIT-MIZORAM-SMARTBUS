import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import '../../controllers/navigation_controller.dart';
import '../../services/maneuver_builder.dart';
import '../../widgets/route_preview_card.dart';
import '../../widgets/route_preview_sheet.dart';
import '../../widgets/navigation_banner.dart';
import '../../widgets/navigation_bottom_bar.dart';
import '../../widgets/bus_bottom_sheet.dart';
import '../../widgets/bus_search_bar.dart';
import '../../widgets/pulsing_dot_marker.dart';
import '../../services/campus_routing_service.dart';
import '../../services/routing_service.dart';

import '../../models/bus_location.dart';
import '../../models/models.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/bus_service.dart';
import '../auth/login_screen.dart';
import '../../utils/mp.dart';

enum MapLayer { street, dark, satellite, terrain }

class MapScreen extends StatefulWidget {
  final BusModel? selectedBus;
  final String? initialStop;

  const MapScreen({super.key, this.selectedBus, this.initialStop});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

@immutable
class _MapOverlaySnapshot {
  final Set<Marker> markers;
  final Set<Circle> circles;
  final Set<Polyline> polylines;
  final MapType mapType;
  final String? mapStyle;
  final bool myLocationEnabled;

  const _MapOverlaySnapshot({
    required this.markers,
    required this.circles,
    required this.polylines,
    required this.mapType,
    required this.mapStyle,
    required this.myLocationEnabled,
  });
}

class _MapOverlayNotifier extends ChangeNotifier {
  _MapOverlaySnapshot _snapshot = const _MapOverlaySnapshot(
    markers: <Marker>{},
    circles: <Circle>{},
    polylines: <Polyline>{},
    mapType: MapType.satellite,
    mapStyle: null,
    myLocationEnabled: false,
  );

  _MapOverlaySnapshot get snapshot => _snapshot;

  void update(_MapOverlaySnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }
}

class BusIssueReportDialog extends StatefulWidget {
  final String token;
  final String? busKey;
  final int? busNumber;

  const BusIssueReportDialog({
    super.key,
    required this.token,
    this.busKey,
    this.busNumber,
  });

  @override
  State<BusIssueReportDialog> createState() => _BusIssueReportDialogState();
}

class _BusIssueReportDialogState extends State<BusIssueReportDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _error;
  bool _isSubmitted = false;

  String _friendlyError(Object error) {
    if (error is ApiResponseException) {
      switch (error.code) {
        case 'ORIGIN_NOT_ALLOWED':
          return 'This app is not allowed to connect to the reporting service.';
        case 'AUTHENTICATION_REQUIRED':
          return 'Please sign in again before submitting a report.';
        case 'ROLE_NOT_ALLOWED':
          return 'Only student accounts can submit reports.';
        case 'PASSWORD_CHANGE_REQUIRED':
          return 'Change your temporary password before submitting a report.';
        case 'STUDENT_HOSTEL_UNASSIGNED':
          return 'Your account has no assigned hostel. Contact your administrator.';
        case 'BUS_HOSTEL_MISMATCH':
          return 'You can only report buses assigned to your hostel.';
      }
    }
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    if (raw.isEmpty) {
      return 'Could not submit report. Please try again.';
    }
    final text = raw.toLowerCase();
    if (text.contains('offline') || text.contains('unreachable')) {
      return 'You are offline. Please connect to the network and try again.';
    }
    if (text.contains('timed out')) {
      return 'The server did not respond in time. Please try again.';
    }
    return 'Could not submit report. Please try again.';
  }

  Future<void> _submit() async {
    final message = _controller.text.trim();
    if (message.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await context.read<ApiService>().submitReport(
        widget.token,
        message: message,
        category: 'other',
        busNumber: widget.busNumber,
      );
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _isSubmitted = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = _friendlyError(error);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isSubmitted) {
      return AlertDialog(
        title: const Text('Report sent'),
        content: const Text('Report submitted successfully.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Report a bus issue'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.busKey != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Bus: ${widget.busKey}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Describe a delay or issue',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting || _controller.text.trim().isEmpty
              ? null
              : _submit,
          child: Text(_isSubmitting ? 'Sending...' : 'Send'),
        ),
      ],
    );
  }
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final Completer<GoogleMapController> _mapController =
      Completer<GoogleMapController>();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<BusLocation> _fleet = [];
  double _mapZoom = 15;
  LatLng? _mapTarget;

  bool _isLoading = true;
  bool _isConnected = false;
  String _connectionStatus = 'Connecting';
  bool _isRefreshing = false;
  bool _isWaking = false;
  bool _isSyncing = false;
  bool _followSelectedBus = true;
  bool _isFleetPanelOpen = false;
  String? _error;

  String? _selectedBusKey;
  String? _lastAutoCameraBusKey;
  DateTime? _lastUpdate;
  Timer? _pollTimer;
  Timer? _wakingTimer;
  StreamSubscription<List<Map<String, dynamic>>>? _liveBusSubscription;
  late AuthService _authService;
  String? _sessionToken;
  LatLng? _lastFollowedPosition;
  final double _followMoveThresholdKm = 0.03; // ~30m
  // Routing state
  LatLng? _lastRouteOrigin; // origin used for last route fetch
  List<LatLng> _currentRoute = [];
  Set<Polyline> _routePolylines = {};
  Timer? _etaTimer;
  String _routeEtaText = '';
  double _routeRemainingKm = 0.0;
  double? _routeDistanceMeters;
  int? _routeDurationSeconds;
  DateTime? _lastRouteRequestAt;
  bool _routeRequestInFlight = false;
  bool _routeUnavailable = false;
  int _routeRequestGeneration = 0;
  // Marker animation state
  final Map<String, LatLng> _animatedPositions = {};
  final Map<String, AnimationController> _markerControllers = {};
  final Map<String, double> _animatedHeadings = {};

  static const LatLng _defaultCenter = LatLng(23.7500, 92.7250);
  static const Map<String, LatLng> _knownHostelCoordinates = {
    'BH1': LatLng(23.792917, 92.727789),
    'BH2': LatLng(23.794311, 92.728146),
    'BH3': LatLng(23.767378, 92.737712),
    'BH4': LatLng(23.769835, 92.737959),
    'GH1': LatLng(23.775578, 92.731044),
    'GH2': LatLng(23.784357, 92.728380),
    'MBSE': LatLng(23.749966, 92.722865),
    'Block 8': LatLng(23.751949, 92.727348),
  };

  static const double _minZoom = 2;
  static const double _maxZoom = 20;

  static const Map<String, Map<String, dynamic>> _stopDefinitions = {
    'BH1': {'label': 'BH1', 'lat': 23.792917, 'lng': 92.727789, 'type': 'boys'},
    'BH2': {'label': 'BH2', 'lat': 23.794311, 'lng': 92.728146, 'type': 'boys'},
    'BH3': {'label': 'BH3', 'lat': 23.767378, 'lng': 92.737712, 'type': 'boys'},
    'BH4': {'label': 'BH4', 'lat': 23.769835, 'lng': 92.737959, 'type': 'boys'},
    'GH1': {
      'label': 'GH1',
      'lat': 23.775578,
      'lng': 92.731044,
      'type': 'girls',
    },
    'GH2': {
      'label': 'GH2',
      'lat': 23.784357,
      'lng': 92.728380,
      'type': 'girls',
    },
    'MBSE': {
      'label': 'MBSE',
      'lat': 23.749966,
      'lng': 92.722865,
      'type': 'academic',
    },
    'B8': {
      'label': 'B8',
      'lat': 23.751949,
      'lng': 92.727348,
      'type': 'academic',
    },
    'Block 8': {
      'label': 'Block 8',
      'lat': 23.751949,
      'lng': 92.727348,
      'type': 'academic',
    },
  };

  static const String _darkMapStyle = '''[
    {"featureType":"all","elementType":"geometry","stylers":[{"color":"#1f2937"}]},
    {"featureType":"all","elementType":"labels.text.fill","stylers":[{"color":"#f3f4f6"}]},
    {"featureType":"all","elementType":"labels.text.stroke","stylers":[{"color":"#111827"},{"lightness":-25}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#374151"}]},
    {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
    {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#4b5563"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0f172a"}]},
    {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#111827"}]},
    {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#111827"}]}
  ]''';

  MapLayer _selectedMapLayer = MapLayer.street;
  final Map<String, LatLng> _lastBusPositions = {};
  final Map<String, DateTime> _lastBusSeenAt = {};
  final Map<String, int> _lastBusSpeedWindow = {};
  final CampusRoutingService _campusRouting = CampusRoutingService();
  final NavigationController _navigation = NavigationController();
  final _MapOverlayNotifier _mapOverlays = _MapOverlayNotifier();
  MapMode? _lastOverlayNavigationMode;
  final FlutterTts _tts = FlutterTts();
  final ValueNotifier<NavigationTelemetry> _navigationTelemetry = ValueNotifier(
    const NavigationTelemetry(gpsStatus: 'GPS SEARCHING'),
  );
  List<Maneuver> _maneuvers = [];
  int _maneuverIndex = 0;
  int _lastAnnouncedManeuver = -1;
  bool _poorGpsAccuracy = false;
  double _userHeading = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _searchDebounce;
  List<String> _suggestions = [];
  LatLng? _searchedPlacePosition;
  String? _searchedPlaceName;
  StreamSubscription<Position>? _userPositionSubscription;
  LatLng? _userPosition;
  bool _trackingUser = false;
  LatLng? _lastRouteBusPosition;
  Timer? _routeUpdateTimer;
  double _userAccuracyMeters = 0;
  Position? _previousUserFix;
  DateTime? _lastUserFixAt;
  double? _userSpeedKmh;
  double _userDistanceTravelledMeters = 0;
  bool _cameraCommandActive = false;
  bool _navigationCameraAnimating = false;
  Timer? _navigationCameraTimer;
  LatLng? _pendingNavigationCameraTarget;
  double _lastCameraBearing = 0;
  int _arrivalFixCount = 0;
  bool _isRerouting = false;
  Timer? _pulseTimer;
  bool _pulseExpanded = false;

  @override
  void initState() {
    super.initState();
    _authService = context.read<AuthService>();
    _sessionToken = _authService.currentUser?.token;
    _authService.addListener(_onAuthChanged);
    if (widget.selectedBus != null) {
      _selectedBusKey = _busKey('Bus ${widget.selectedBus!.busNumber}');
    }
    _lastOverlayNavigationMode = _navigation.mode;
    _refreshMapOverlays();
    _navigation.addListener(_onNavigationChanged);
    _configureTts();
    _bootstrap();
    if (widget.initialStop != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stopDefinitions.containsKey(widget.initialStop)) {
          _chooseStop(widget.initialStop!);
        }
      });
    }
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
      if (mounted && _fleet.any(_running)) {
        _pulseExpanded = !_pulseExpanded;
        _refreshMapOverlays();
      }
    });
    // ETA updater: cheap, runs every 1s (no network)
    _etaTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateEta());
  }

  void _onNavigationChanged() {
    if (_lastOverlayNavigationMode != _navigation.mode) {
      _lastOverlayNavigationMode = _navigation.mode;
      _refreshMapOverlays();
    }
    if (mounted) setState(() {});
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.48);
  }

  @override
  void dispose() {
    _authService.removeListener(_onAuthChanged);
    _pollTimer?.cancel();
    unawaited(_liveBusSubscription?.cancel());
    _wakingTimer?.cancel();
    _etaTimer?.cancel();
    _searchDebounce?.cancel();
    _routeUpdateTimer?.cancel();
    _navigationCameraTimer?.cancel();
    _pulseTimer?.cancel();
    _userPositionSubscription?.cancel();
    _navigation.removeListener(_onNavigationChanged);
    _navigation.dispose();
    _mapOverlays.dispose();
    _navigationTelemetry.dispose();
    _tts.stop();
    WakelockPlus.disable();
    _searchController.dispose();
    _searchFocusNode.dispose();
    // _navigation and _mapOverlays are owned by this State; the providers in
    // main.dart own different service notifiers and should not be disposed here.
    for (final c in _markerControllers.values) {
      c.stop();
      c.dispose();
    }
    super.dispose();
  }

  void _animateMarker(String key, LatLng from, LatLng to) {
    final animatedFrom = _animatedPositions[key] ?? from;
    final existing = _markerControllers[key];
    existing?.stop();
    existing?.dispose();

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _markerControllers[key] = controller;

    controller.addListener(() {
      final t = controller.value;
      final lat =
          animatedFrom.latitude + (to.latitude - animatedFrom.latitude) * t;
      final lng =
          animatedFrom.longitude + (to.longitude - animatedFrom.longitude) * t;
      _animatedPositions[key] = LatLng(lat, lng);
      _refreshMapOverlays();
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        _animatedPositions[key] = to;
        controller.dispose();
        _markerControllers.remove(key);
      }
    });
    controller.forward();
  }

  Future<void> _bootstrap() async {
    await _syncFleet();
    if (!mounted) return;
    final token = _sessionToken;
    if (token != null && _authService.currentUser?.token == token && mounted) {
      _liveBusSubscription = context
          .read<ApiService>()
          .streamBusUpdates(
            token,
            isSessionValid: () => _authService.currentUser?.token == token,
            onUnauthorized: () => _handleStreamUnauthorized(token),
          )
          .listen(
            _applyLiveBusUpdates,
            onError: (_) {
              if (mounted && _authService.currentUser?.token == token) {
                setState(() => _isConnected = false);
              }
            },
          );
    }
    if (_sessionToken != null &&
        _authService.currentUser?.token == _sessionToken) {
      _pollTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _syncFleet(silent: true),
      );
    }
  }

  void _onAuthChanged() {
    if (_sessionToken == _authService.currentUser?.token) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _wakingTimer?.cancel();
    final subscription = _liveBusSubscription;
    _liveBusSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  Future<void> _handleStreamUnauthorized(String token) async {
    final expired = await _authService.expireSession(token);
    if (!expired || !mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  void _applyLiveBusUpdates(List<Map<String, dynamic>> updates) {
    if (!mounted || updates.isEmpty) return;
    final next = List<BusLocation>.from(_fleet);
    for (final json in updates) {
      final bus = _fromBusJson(json);
      final key = _busKey(bus.busId);
      final index = next.indexWhere((item) => _busKey(item.busId) == key);
      final old = index >= 0 ? next[index] : null;
      if (old != null && old.timestamp.isAfter(bus.timestamp)) continue;
      final point = LatLng(bus.lat, bus.lng);
      final previous = _lastBusPositions[key];
      if (bus.heading.isFinite && bus.heading > 0) {
        _animatedHeadings[key] = bus.heading;
      } else if (previous != null && _distanceKm(previous, point) > .002) {
        _animatedHeadings[key] = _bearingBetween(previous, point);
      }
      if (previous != null && _distanceKm(previous, point) > 0.001) {
        _animateMarker(key, previous, point);
      } else if (previous == null) {
        _animatedPositions[key] = point;
      }
      _lastBusPositions[key] = point;
      _lastBusSeenAt[key] = bus.timestamp;
      _lastBusSpeedWindow[key] = bus.speed.round();
      if (index >= 0) {
        next[index] = BusLocation(
          busId: bus.busId,
          deviceId: bus.deviceId,
          assignedHostel: bus.assignedHostel.isEmpty
              ? old!.assignedHostel
              : bus.assignedHostel,
          lat: bus.lat,
          lng: bus.lng,
          speed: bus.speed,
          heading: bus.heading,
          accuracy: bus.accuracy,
          status: bus.status,
          timestamp: bus.timestamp,
        );
      } else {
        next.add(bus);
      }
    }
    setState(() {
      _fleet = next;
      _isConnected = true;
      _connectionStatus = 'Connected';
      _isLoading = false;
      _isWaking = false;
      _lastUpdate = DateTime.now();
    });
    _refreshMapOverlays();
  }

  Future<void> _syncFleet({bool silent = false, bool showToast = false}) async {
    if (!mounted || _isSyncing) return;
    final requestToken = _sessionToken;
    if (requestToken == null ||
        _authService.currentUser?.token != requestToken) {
      return;
    }
    _isSyncing = true;
    if (!_isConnected && mounted) {
      setState(() => _connectionStatus = 'Reconnecting');
    }
    _wakingTimer?.cancel();
    _wakingTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isSyncing) setState(() => _isWaking = true);
    });

    final api = context.read<ApiService>();
    final auth = context.read<AuthService>();
    final busService = context.read<BusService>();

    try {
      if (!silent) {
        setState(() => _isLoading = true);
      }
      if (showToast) {
        setState(() => _isRefreshing = true);
      }

      final currentUser = auth.currentUser;
      final busesData =
          currentUser?.role == 'student' || currentUser?.role == 'caretaker'
          ? await api.getTodayScheduledBuses(token: currentUser!.token!)
          : await api.getBuses(token: currentUser?.token);

      if (currentUser?.role == 'driver') {
        await busService.loadBuses(api, token: currentUser?.token);
        await busService.loadSchedules(api, token: currentUser?.token);
      }

      var fleet = busesData
          .whereType<Map<String, dynamic>>()
          .map(_fromBusJson)
          .toList();

      final latest = currentUser?.token == null
          ? null
          : await ApiService.fetchLatestLocation(token: currentUser!.token!);
      if (!mounted || _authService.currentUser?.token != requestToken) return;
      if (latest != null) {
        fleet = _mergeLatestTelemetry(fleet, latest);
      }

      // Preserve previously received server positions when today's schedule
      // is empty. Never label local seed coordinates as a fresh GPS reading.
      if (fleet.isEmpty && _fleet.isNotEmpty) {
        fleet = List<BusLocation>.from(_fleet);
      }

      final selectedKey =
          _selectedBusKey ??
          (widget.selectedBus != null
              ? _busKey('Bus ${widget.selectedBus!.busNumber}')
              : (fleet.isNotEmpty ? _busKey(fleet.first.busId) : null));

      final selectedBus = _findByKey(fleet, selectedKey);
      if (_followSelectedBus && selectedBus != null) {
        final shouldRecenter = _lastAutoCameraBusKey != selectedKey;
        final newPos = LatLng(selectedBus.lat, selectedBus.lng);
        final lastPos = _lastFollowedPosition;
        // Recenter if the selected bus changed, or it moved more than threshold
        final movedEnough = lastPos == null
            ? true
            : _distanceKm(lastPos, newPos) >= _followMoveThresholdKm;
        if (shouldRecenter || movedEnough) {
          _lastAutoCameraBusKey = selectedKey;
          _lastFollowedPosition = newPos;
          // use immediate move for frequent updates to avoid animation buffering
          await _moveCameraTo(newPos, zoom: _mapZoom);
        }
      } else {
        _lastAutoCameraBusKey = null;
        _lastFollowedPosition = null;
      }

      for (final bus in fleet) {
        final key = _busKey(bus.busId);
        final current = LatLng(bus.lat, bus.lng);
        final prev = _lastBusPositions[key];
        if (prev != null) {
          final moved = _distanceKm(prev, current) > 0.001;
          if (moved) {
            _animatedHeadings[key] = bus.heading > 0
                ? bus.heading
                : _bearingBetween(prev, current);
            // animate marker from prev -> current (cheap, local)
            _animateMarker(key, prev, current);
            _lastBusPositions[key] = current;
            _lastBusSeenAt[key] = bus.timestamp;
          }
        } else {
          // initialize animated position
          _animatedPositions[key] = current;
          _lastBusPositions[key] = current;
          _lastBusSeenAt[key] = bus.timestamp;
          if (bus.heading > 0) _animatedHeadings[key] = bus.heading;
        }
        _lastBusSpeedWindow[key] = bus.speed.round();
      }

      if (!mounted || _authService.currentUser?.token != requestToken) return;
      setState(() {
        _fleet = fleet;
        _selectedBusKey = selectedKey;
        _isLoading = false;
        _isRefreshing = false;
        _isWaking = false;
        // Reaching this point means the authenticated bus endpoint and the
        // latest-location endpoint both returned successfully. GPS freshness
        // is tracked separately from server connectivity via each bus timestamp.
        _isConnected = true;
        _connectionStatus = 'Connected';
        _error = null;
        _lastUpdate = DateTime.now();
      });
      _refreshMapOverlays();

      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bus data refreshed'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted || _authService.currentUser?.token != requestToken) return;
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _isWaking = false;
        _isConnected = false;
        _connectionStatus = _fleet.isEmpty ? 'Offline' : 'Showing cached data';
        _error = e.toString().replaceAll('Exception: ', '');
      });

      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Refresh failed: ${_error ?? 'Unable to load bus data'}',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _wakingTimer?.cancel();
      _wakingTimer = null;
      _isWaking = false;
      _isSyncing = false;
    }
  }

  BusLocation _fromBusJson(Map<String, dynamic> bus) {
    final number = bus['busNumber']?.toString() ?? 'Unknown';
    final rawTimestamp =
        bus['lastUpdated'] ?? bus['received_at'] ?? bus['timestamp'];
    final busTimestamp = rawTimestamp == null
        ? (bus.containsKey('lastUpdated')
              ? DateTime.fromMillisecondsSinceEpoch(0)
              : DateTime.now())
        : (DateTime.tryParse(rawTimestamp.toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0));
    return BusLocation(
      busId: 'Bus $number',
      deviceId: (bus['deviceId'] ?? 'device-$number').toString(),
      assignedHostel: (bus['assignedHostel'] ?? bus['assigned_hostel'] ?? '')
          .toString(),
      lat: ((bus['latitude'] ?? bus['lat'] ?? 23.7271) as num).toDouble(),
      lng: ((bus['longitude'] ?? bus['lng'] ?? 92.7176) as num).toDouble(),
      speed: ((bus['speed'] ?? 0) as num).toDouble(),
      heading: ((bus['heading'] ?? 0) as num).toDouble(),
      accuracy: ((bus['accuracy'] ?? bus['hdop'] ?? 1.0) as num).toDouble(),
      status: (bus['status'] ?? 'idle').toString(),
      timestamp: busTimestamp,
    );
  }

  List<BusLocation> _mergeLatestTelemetry(
    List<BusLocation> fleet,
    BusLocation latest,
  ) {
    final latestKey = _busKey(latest.busId);
    final index = fleet.indexWhere((bus) => _busKey(bus.busId) == latestKey);

    if (index == -1) {
      return [...fleet, latest];
    }

    final previous = fleet[index];
    final next = List<BusLocation>.from(fleet);
    next[index] = BusLocation(
      busId: latest.busId,
      deviceId: latest.deviceId,
      assignedHostel: previous.assignedHostel,
      lat: latest.lat,
      lng: latest.lng,
      speed: latest.speed,
      heading: latest.heading,
      accuracy: latest.accuracy,
      status: latest.status,
      timestamp: latest.timestamp,
    );
    return next;
  }

  String _busKey(String busId) {
    final digits = busId.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? busId : digits;
  }

  BusLocation? _findByKey(List<BusLocation> fleet, String? key) {
    if (key == null) return null;
    for (final bus in fleet) {
      if (_busKey(bus.busId) == key) return bus;
    }
    return null;
  }

  void _toggleFleetPanel() {
    setState(() {
      _isFleetPanelOpen = !_isFleetPanelOpen;
    });
  }

  LatLng _clampToCampus(LatLng point) {
    return LatLng(
      point.latitude.clamp(-85.0, 85.0),
      point.longitude.clamp(-180.0, 180.0),
    );
  }

  double _bearingBetween(LatLng from, LatLng to) {
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final dLon = (to.longitude - from.longitude) * pi / 180;

    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final angle = atan2(y, x) * 180 / pi;
    return (angle + 360) % 360;
  }

  LatLng? _getHostelCoordinates(String hostel) {
    return _knownHostelCoordinates[hostel];
  }

  double _distanceKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final lat1 = a.latitude * (pi / 180);
    final lat2 = b.latitude * (pi / 180);
    final dLat = lat2 - lat1;
    final dLng = (b.longitude - a.longitude) * (pi / 180);
    final h =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return 2 * r * asin(sqrt(h));
  }

  String _routeLabel(BusLocation bus) {
    if (bus.assignedHostel.isEmpty) return 'Hostel ↔ MBSE';
    return 'Hostel ↔ ${bus.assignedHostel}';
  }

  MapType get _mapType {
    switch (_selectedMapLayer) {
      case MapLayer.street:
        return MapType.normal;
      case MapLayer.dark:
        return MapType.normal;
      case MapLayer.satellite:
        return MapType.satellite;
      case MapLayer.terrain:
        return MapType.terrain;
    }
  }

  Future<void> _applyMapStyle() async {
    return;
  }

  Future<void> _moveCameraTo(
    LatLng target, {
    double? zoom,
    bool animate = true,
  }) async {
    if (!_mapController.isCompleted) return;
    final controller = await _mapController.future;
    final finalZoom = zoom ?? _mapZoom;
    final update = CameraUpdate.newCameraPosition(
      CameraPosition(target: _clampToCampus(target), zoom: finalZoom),
    );
    if (animate) {
      await controller.animateCamera(update);
    } else {
      // use immediate move to avoid animation buffering during frequent updates
      await controller.moveCamera(update);
    }
  }

  void _handleSearchQuery(String text) {
    final query = text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (query.isEmpty) return;
    final bus = _fleet.where((item) {
      final id = item.busId.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final number = _busKey(item.busId).toLowerCase();
      final cleaned = query.replaceFirst('bus', '');
      return id.contains(query) || number.contains(cleaned);
    }).firstOrNull;
    if (bus != null) {
      _chooseBus(bus);
      return;
    }
    final stop = _stopDefinitions.keys
        .where(
          (item) => item.toLowerCase().replaceAll(RegExp(r'\s+'), '') == query,
        )
        .firstOrNull;
    if (stop != null) {
      _chooseStop(stop);
      return;
    }
    _searchPlaces(text.trim(), selectFirst: true);
  }

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await _syncFleet(silent: true, showToast: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Refresh failed. Please try again.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _onMapCreated(GoogleMapController controller) async {
    _mapController.complete(controller);
    await _applyMapStyle();
    final selected = _findByKey(_fleet, _selectedBusKey);
    if (selected != null) {
      await _moveCameraTo(LatLng(selected.lat, selected.lng), zoom: _mapZoom);
    }
  }

  void _buildRoutePolylines() {
    final outline = Polyline(
      polylineId: const PolylineId('route_outline'),
      points: _currentRoute,
      color: const Color(0xE6101827),
      width: 12,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
      geodesic: false,
    );

    final main = Polyline(
      polylineId: const PolylineId('route_main'),
      points: _currentRoute,
      color: const Color(0xFF0F52BA),
      width: 8,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
      geodesic: false,
    );

    _routePolylines = {outline, main};
    _refreshMapOverlays();
  }

  // Cheap: update ETA and remaining distance every 1s without network
  void _updateEta() {
    if (_currentRoute.isEmpty) {
      _routeEtaText = _routeUnavailable ? '--' : '';
      _routeRemainingKm = 0.0;
      _updateNavigationTelemetry();
      if (mounted && _trackingUser) {
        setState(() {});
        _updateNavigationProgress();
      }
      return;
    }
    final bus = _findByKey(_fleet, _selectedBusKey);
    if (bus == null) return;
    final current = _userPosition ?? LatLng(bus.lat, bus.lng);
    final km = _remainingRouteMeters(current, _currentRoute) / 1000;
    _routeRemainingKm = km;
    final fullDistance =
        _routeDistanceMeters ?? _pathDistanceMeters(_currentRoute);
    final providerEta = _routeDurationSeconds == null || fullDistance <= 0
        ? null
        : (_routeDurationSeconds! * (km * 1000 / fullDistance)).round();
    final liveEta = _userSpeedKmh != null && _userSpeedKmh! > 2
        ? (km / _userSpeedKmh! * 3600).round()
        : null;
    final etaSeconds = liveEta ?? providerEta;
    _routeEtaText = etaSeconds == null
        ? '--'
        : '${(etaSeconds / 60).ceil()} min';
    _navigation.setSummary(_routeEtaText, '${(km * 1000).round()} m');
    _updateNavigationTelemetry();
    if (_navigation.mode == MapMode.routePreview) _refreshMapOverlays();
    if (mounted && _trackingUser) {
      setState(() {});
      _updateNavigationProgress();
    }
  }

  void _updateNavigationTelemetry() {
    final fixTime = _lastUserFixAt;
    final isFresh =
        fixTime != null &&
        DateTime.now().difference(fixTime) <= const Duration(seconds: 12);
    final status = !_isConnected
        ? 'CONNECTION LOST'
        : !_trackingUser || fixTime == null
        ? 'GPS SEARCHING'
        : !isFresh
        ? 'GPS SIGNAL LOST'
        : _poorGpsAccuracy
        ? 'GPS SIGNAL WEAK'
        : 'GPS • LIVE';
    final selectedBus = _findByKey(_fleet, _selectedBusKey);
    final resolvedStatus = selectedBus != null && _isStale(selectedBus)
        ? 'BUS SIGNAL STALE'
        : status;
    final speed = _trackingUser && isFresh ? _userSpeedKmh : null;
    final current = _navigationTelemetry.value;
    if (current.speedKmh != speed || current.gpsStatus != resolvedStatus) {
      _navigationTelemetry.value = NavigationTelemetry(
        speedKmh: speed,
        gpsStatus: resolvedStatus,
      );
    }
  }

  double _pathDistanceMeters(List<LatLng> points) {
    var meters = 0.0;
    for (var i = 1; i < points.length; i++) {
      meters += _distanceKm(points[i - 1], points[i]) * 1000;
    }
    return meters;
  }

  double _remainingRouteMeters(LatLng position, List<LatLng> path) {
    if (path.length < 2) return 0;
    var closestIndex = 0;
    var closestDistance = double.infinity;
    for (var i = 0; i < path.length; i++) {
      final distance = _distanceKm(position, path[i]);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = i;
      }
    }
    return _pathDistanceMeters(path.skip(closestIndex).toList());
  }

  bool _isStale(BusLocation bus) =>
      DateTime.now().difference(bus.timestamp) > const Duration(seconds: 120);

  bool _running(BusLocation bus) =>
      !_isStale(bus) &&
      (bus.speed > 2 ||
          const {
            'running',
            'active',
            'moving',
          }.contains(bus.status.toLowerCase()));

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final query = value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      final local = query.isEmpty
          ? <String>[]
          : [
              ..._fleet
                  .where((bus) {
                    final id = bus.busId.toLowerCase().replaceAll(
                      RegExp(r'\s+'),
                      '',
                    );
                    final number = _busKey(bus.busId).toLowerCase();
                    final cleaned = query.replaceFirst('bus', '');
                    return id.contains(query) || number.contains(cleaned);
                  })
                  .map((bus) => 'bus:${bus.busId}'),
              ..._stopDefinitions.keys
                  .where(
                    (stop) => stop
                        .toLowerCase()
                        .replaceAll(RegExp(r'\s+'), '')
                        .contains(query),
                  )
                  .map((stop) => 'stop:$stop'),
            ].take(5).toList();
      if (query.isEmpty) {
        setState(() => _suggestions = []);
      } else {
        setState(() => _suggestions = local);
        _searchPlaces(value.trim(), local: local);
      }
    });
  }

  Future<void> _searchPlaces(
    String query, {
    List<String> local = const [],
    bool selectFirst = false,
  }) async {
    final key = MP.googleMapsApiKey;
    if (key.isEmpty) {
      if (selectFirst && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Add GOOGLE_MAPS_API_KEY and enable Places API to search places.',
            ),
          ),
        );
      }
      return;
    }
    if (query.length < 2) return;
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        {'input': query, 'key': key},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final places = <String>[];
      if (data['status'] == 'OK' && data['predictions'] is List) {
        for (final prediction in data['predictions'] as List) {
          if (prediction is Map<String, dynamic>) {
            final id = prediction['place_id']?.toString();
            final description = prediction['description']?.toString();
            if (id != null && description != null) {
              places.add('place:$id|$description');
            }
          }
        }
      }
      if (!mounted || _searchController.text.trim() != query) return;
      if (selectFirst && places.isNotEmpty) {
        final first = places.first.substring(6).split('|');
        if (first.length == 2) {
          await _choosePlace(first[0], first[1]);
          return;
        }
      }
      setState(() => _suggestions = [...local, ...places].take(8).toList());
    } catch (_) {}
  }

  Future<void> _choosePlace(String id, String description) async {
    final key = MP.googleMapsApiKey;
    if (key.isEmpty) return;
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/details/json',
        {'place_id': id, 'fields': 'geometry/location,name', 'key': key},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final location =
          ((data['result'] as Map<String, dynamic>?)?['geometry']
                  as Map<String, dynamic>?)?['location']
              as Map<String, dynamic>?;
      if (response.statusCode != 200 ||
          data['status'] != 'OK' ||
          location == null) {
        throw Exception();
      }
      final point = LatLng(
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      );
      if (!mounted) return;
      setState(() {
        _searchedPlacePosition = point;
        _searchedPlaceName =
            ((data['result'] as Map<String, dynamic>)['name'] ?? description)
                .toString();
        _selectedBusKey = null;
        _suggestions = [];
      });
      _searchController.text = description;
      _searchFocusNode.unfocus();
      _refreshMapOverlays();
      await _moveCameraTo(point, zoom: 16);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not find that location. Check Google Places API access.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _chooseBus(BusLocation bus) async {
    setState(() {
      _selectedBusKey = _busKey(bus.busId);
      _suggestions = [];
      _followSelectedBus = false;
    });
    _refreshMapOverlays();
    _searchController.text = bus.busId;
    _searchFocusNode.unfocus();
    await _moveCameraTo(LatLng(bus.lat, bus.lng), zoom: 16);
    if (mounted) _showBusDetails(bus);
  }

  void _chooseStop(String name) {
    final stop = _stopDefinitions[name]!;
    final point = LatLng(
      (stop['lat'] as num).toDouble(),
      (stop['lng'] as num).toDouble(),
    );
    setState(() {
      _selectedBusKey = null;
      _suggestions = [];
    });
    _refreshMapOverlays();
    _searchController.text = name;
    _searchFocusNode.unfocus();
    _moveCameraTo(point, zoom: 16);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Row(
            children: [
              const Icon(Icons.place, color: Color(0xFF2563EB)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  if (_fleet.isEmpty) return;
                  final bus = _fleet.reduce(
                    (a, b) =>
                        _distanceKm(point, LatLng(a.lat, a.lng)) <
                            _distanceKm(point, LatLng(b.lat, b.lng))
                        ? a
                        : b,
                  );
                  _chooseBus(bus);
                },
                child: const Text('Find buses'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBusDetails(BusLocation bus) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: .34,
        minChildSize: .20,
        maxChildSize: .85,
        snap: true,
        snapSizes: const [.20, .45, .85],
        builder: (context, controller) {
          final running = _running(bus);
          final number = int.tryParse(_busKey(bus.busId));
          final busModel =
              context
                  .read<BusService>()
                  .buses
                  .where((item) => item.busNumber == number)
                  .firstOrNull ??
              (widget.selectedBus?.busNumber == number
                  ? widget.selectedBus
                  : null);
          return BusBottomSheet(
            scrollController: controller,
            bus: bus,
            route: _routeLabel(bus),
            updated: _timeAgo(bus.timestamp),
            running: running,
            nextStop: running && bus.assignedHostel.isNotEmpty
                ? '${bus.assignedHostel} · ${_nextStopEta(bus)}'
                : '',
            schedule: busModel?.schedule == null
                ? ''
                : '${busModel!.schedule!.fromHostelTime} from hostel · ${busModel.schedule!.fromMBSETime} from MBSE',
            driverName: busModel?.driver?.name ?? '',
            driverPhone: busModel?.driver?.phone,
            showAdvanced: context.read<AuthService>().isAdmin,
            tracking: _trackingUser,
            onCall: busModel?.driver == null
                ? null
                : () => _callDriver(busModel!.driver!.phone),
            onDirections: () {
              Navigator.of(context).pop();
              _openRoutePreview(bus);
            },
            onStop: () {
              _stopUserTracking();
              _navigation.browse();
            },
          );
        },
      ),
    );
  }

  Future<void> _openRoutePreview(BusLocation bus) async {
    setState(() {
      _selectedBusKey = _busKey(bus.busId);
      _isFleetPanelOpen = false;
      _suggestions = [];
    });
    _navigation.showPreview();
    await _startTracking(bus);
    if (!mounted) return;
    if (_userPosition == null) {
      _navigation.browse();
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: .36,
        minChildSize: .25,
        maxChildSize: .72,
        snap: true,
        snapSizes: const [.25, .5, .72],
        builder: (context, controller) {
          final selected = _findByKey(_fleet, _selectedBusKey);
          return SingleChildScrollView(
            controller: controller,
            child: RoutePreviewSheet(
              controller: _navigation,
              busName: selected?.busId ?? bus.busId,
              eta: _routeEtaText.isEmpty ? 'Calculating…' : _routeEtaText,
              distance: _formatDistance(_routeRemainingKm * 1000),
              busEta: _nextStopEta(bus),
              speed: (selected?.speed ?? bus.speed).toStringAsFixed(0),
              onStart: () {
                Navigator.of(sheetContext).pop();
                _enterNavigation();
              },
              onClose: () {
                Navigator.of(sheetContext).pop();
                _navigation.browse();
                _stopUserTracking();
              },
              onShare: _shareEta,
            ),
          );
        },
      ),
    );
  }

  Future<void> _enterNavigation() async {
    _navigation.start();
    await WakelockPlus.enable();
    final user = _userPosition;
    if (user != null && _mapController.isCompleted) {
      await _animateNavigationCamera(user, immediate: true);
    }
    _updateNavigationProgress();
  }

  Future<void> _endNavigation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End navigation?'),
        content: const Text('You can start a new route at any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep navigating'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _stopUserTracking();
    _navigation.browse();
    await WakelockPlus.disable();
  }

  Future<void> _shareEta() async {
    final bus = _findByKey(_fleet, _selectedBusKey);
    final text =
        '${bus?.busId ?? 'Campus bus'} · ${_routeEtaText.isEmpty ? 'ETA unavailable' : '$_routeEtaText away'}';
    await SharePlus.instance.share(ShareParams(text: text));
  }

  Future<void> _reportIssue() async {
    final currentUser = context.read<AuthService>().currentUser;
    final token = currentUser?.token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please sign in again to send a report.'),
          ),
        );
      }
      return;
    }

    final selectedBus = _findByKey(_fleet, _selectedBusKey);
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => BusIssueReportDialog(
        token: token,
        busKey: _selectedBusKey,
        busNumber: selectedBus == null
            ? null
            : int.tryParse(_busKey(selectedBus.busId)),
      ),
    );

    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report submitted successfully.')),
      );
    }
  }

  void _updateNavigationProgress() {
    if (_navigation.mode != MapMode.navigating ||
        _userPosition == null ||
        _maneuvers.isEmpty) {
      return;
    }
    final selectedBus = _findByKey(_fleet, _selectedBusKey);
    if (selectedBus != null) {
      final destination = LatLng(selectedBus.lat, selectedBus.lng);
      final destinationDistance =
          _distanceKm(_userPosition!, destination) * 1000;
      if (destinationDistance <= 25 && !_poorGpsAccuracy) {
        _arrivalFixCount++;
      } else {
        _arrivalFixCount = 0;
      }
      if (_arrivalFixCount >= 3) {
        _navigation.arrive();
        _routeUpdateTimer?.cancel();
        if (!_navigation.muted) _tts.speak('You have arrived');
        return;
      }
    }
    final maneuver = _maneuvers[_maneuverIndex.clamp(0, _maneuvers.length - 1)];
    final meters = _distanceKm(_userPosition!, maneuver.point) * 1000;
    if (meters <= 200 && _lastAnnouncedManeuver != _maneuverIndex) {
      if (!_navigation.muted) {
        _tts.speak(
          'In ${meters.round()} meters, ${maneuver.instruction.toLowerCase()} onto ${maneuver.roadName}',
        );
      }
      _lastAnnouncedManeuver = _maneuverIndex;
      if (_maneuverIndex < _maneuvers.length - 1) _maneuverIndex++;
    }
    if (_navigation.following && _mapController.isCompleted) {
      _queueNavigationCamera(_userPosition!);
    }
  }

  Future<void> _startTracking(BusLocation bus) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Track a route to this bus?'),
        content: const Text(
          'Your location is used to show a route from you to the selected bus.',
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
    if (accepted != true || !mounted) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Location permission needed'),
          content: const Text(
            'Enable location access in Settings to track a route to the bus.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later'),
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
      return;
    }
    if (permission == LocationPermission.denied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission was not granted.')),
        );
      }
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Turn on location services to start tracking.'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: Geolocator.openLocationSettings,
            ),
          ),
        );
      }
      return;
    }
    await _userPositionSubscription?.cancel();
    setState(() {
      _trackingUser = true;
    });
    _refreshMapOverlays();
    _routeUpdateTimer?.cancel();
    _routeUpdateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final latest = _findByKey(_fleet, _selectedBusKey);
      if (_trackingUser &&
          _navigation.mode != MapMode.arrived &&
          latest != null) {
        _updateUserRoute(latest);
      }
    });
    _userPositionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 1,
          ),
        ).listen((position) {
          if (!_acceptUserFix(position)) return;
          final latest = _findByKey(_fleet, _selectedBusKey) ?? bus;
          _updateUserRoute(latest);
          _updateNavigationProgress();
          if (_navigation.mode == MapMode.navigating && _navigation.following) {
            _queueNavigationCamera(_userPosition!);
          }
        });
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 1,
        ),
      );
      if (_acceptUserFix(position)) {
        await _updateUserRoute(bus);
        _updateNavigationProgress();
      }
    } catch (_) {}
  }

  bool _acceptUserFix(Position position) {
    final point = LatLng(position.latitude, position.longitude);
    final accuracy = position.accuracy;
    final timestamp = position.timestamp;
    _poorGpsAccuracy = !accuracy.isFinite || accuracy > 50;
    _userAccuracyMeters = accuracy.isFinite ? accuracy : 0;
    final fixAge = DateTime.now().difference(timestamp);
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude < -90 ||
        point.latitude > 90 ||
        point.longitude < -180 ||
        point.longitude > 180 ||
        fixAge > const Duration(seconds: 30) ||
        fixAge < const Duration(seconds: -5) ||
        !accuracy.isFinite ||
        accuracy > 100) {
      _updateNavigationTelemetry();
      return false;
    }
    final previous = _previousUserFix;
    double? derivedSpeedKmh;
    double? derivedHeading;
    var stepDistanceMeters = 0.0;
    if (previous != null) {
      final elapsed =
          timestamp.difference(previous.timestamp).inMilliseconds / 1000;
      if (elapsed <= 0) return false;
      final previousPoint = LatLng(previous.latitude, previous.longitude);
      final distanceMeters = _distanceKm(previousPoint, point) * 1000;
      if (distanceMeters > 150 && elapsed < 2) return false;
      stepDistanceMeters = distanceMeters;
      derivedSpeedKmh = distanceMeters / elapsed * 3.6;
      if (distanceMeters > 2) {
        derivedHeading = _bearingBetween(previousPoint, point);
      }
    }

    final deviceSpeed =
        position.speed.isFinite && position.speed >= 0 && position.speed <= 55
        ? position.speed * 3.6
        : null;
    final measuredSpeed = deviceSpeed ?? derivedSpeedKmh;
    if (measuredSpeed != null && measuredSpeed.isFinite) {
      _userSpeedKmh = _userSpeedKmh == null
          ? measuredSpeed
          : _userSpeedKmh! * .65 + measuredSpeed * .35;
    }

    final reportedHeading = position.heading;
    final heading =
        reportedHeading.isFinite &&
            reportedHeading >= 0 &&
            reportedHeading < 360 &&
            (_userSpeedKmh ?? 0) > 1
        ? reportedHeading
        : derivedHeading;
    if (heading != null && heading.isFinite) {
      final delta = ((heading - _userHeading + 540) % 360) - 180;
      _userHeading = (_userHeading + delta * .35 + 360) % 360;
    }

    final previousPoint = _userPosition;
    _userPosition = point;
    if (stepDistanceMeters > max(3, accuracy * .5)) {
      _userDistanceTravelledMeters += stepDistanceMeters;
    }
    if (previousPoint != null && _distanceKm(previousPoint, point) > .001) {
      _animateMarker('user', previousPoint, point);
    } else {
      _animatedPositions['user'] = point;
    }
    _previousUserFix = position;
    _lastUserFixAt = timestamp;
    _updateNavigationTelemetry();
    _refreshMapOverlays();
    return true;
  }

  Future<void> _updateUserRoute(BusLocation bus) async {
    final origin = _userPosition;
    if (origin == null || !mounted) return;
    final destination = LatLng(bus.lat, bus.lng);
    final now = DateTime.now();
    final initialRoute = _currentRoute.length < 2;
    final movedFromRoute =
        _lastRouteOrigin == null ||
        _distanceKm(_lastRouteOrigin!, origin) >= .05;
    final destinationMoved =
        _lastRouteBusPosition == null ||
        _distanceKm(_lastRouteBusPosition!, destination) >= .05;
    final offRoute =
        _currentRoute.length > 1 &&
        _distanceToRouteMeters(origin, _currentRoute) > 55;
    final needsRefresh =
        initialRoute || movedFromRoute || destinationMoved || offRoute;
    final cooldownElapsed =
        _lastRouteRequestAt == null ||
        now.difference(_lastRouteRequestAt!) >= const Duration(seconds: 10);
    if (!needsRefresh || _routeRequestInFlight || !cooldownElapsed) {
      return;
    }

    _routeRequestInFlight = true;
    _lastRouteRequestAt = now;
    final generation = ++_routeRequestGeneration;
    final selectedBusKey = _busKey(bus.busId);
    _isRerouting = !initialRoute;
    if (mounted) setState(() {});
    try {
      final route = await RoutingService.getRoute(
        origin,
        destination,
        mode: TravelMode.driving,
      );
      final primary = route?.primary;
      var points = primary?.geometry ?? const <LatLng>[];
      var durationSeconds = primary?.durationSeconds;
      var distanceMeters = primary?.distanceMeters.toDouble();
      if (points.length < 2) {
        points = await _campusRouting.route(origin, destination);
        durationSeconds = null;
        distanceMeters = null;
      }
      if (!mounted ||
          generation != _routeRequestGeneration ||
          selectedBusKey != _selectedBusKey) {
        return;
      }
      if (points.length < 2) {
        _routeUnavailable = _currentRoute.length < 2;
        return;
      }

      _currentRoute = points;
      _routeDurationSeconds = durationSeconds;
      _routeDistanceMeters = distanceMeters != null && distanceMeters > 0
          ? distanceMeters
          : _pathDistanceMeters(points);
      _routeUnavailable = false;
      _lastRouteOrigin = origin;
      _lastRouteBusPosition = destination;
      _maneuvers = buildManeuvers(points);
      _maneuverIndex = 0;
      _lastAnnouncedManeuver = -1;
      _arrivalFixCount = 0;
      _buildRoutePolylines();
      _updateEta();
      if (_mapController.isCompleted &&
          _navigation.mode != MapMode.navigating) {
        await _fitRouteBounds(origin, destination);
      }
    } catch (_) {
      if (generation == _routeRequestGeneration) {
        _routeUnavailable = _currentRoute.length < 2;
      }
    } finally {
      if (generation == _routeRequestGeneration) {
        _routeRequestInFlight = false;
        _isRerouting = false;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _fitRouteBounds(LatLng origin, LatLng destination) async {
    if (!_mapController.isCompleted) return;
    final map = await _mapController.future;
    await map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            min(origin.latitude, destination.latitude),
            min(origin.longitude, destination.longitude),
          ),
          northeast: LatLng(
            max(origin.latitude, destination.latitude),
            max(origin.longitude, destination.longitude),
          ),
        ),
        100,
      ),
    );
  }

  Future<void> _stopUserTracking() async {
    await _userPositionSubscription?.cancel();
    _userPositionSubscription = null;
    _routeUpdateTimer?.cancel();
    _routeUpdateTimer = null;
    _navigationCameraTimer?.cancel();
    _pendingNavigationCameraTarget = null;
    _routeRequestGeneration++;
    _routeRequestInFlight = false;
    _lastRouteRequestAt = null;
    _routeDurationSeconds = null;
    _routeDistanceMeters = null;
    _previousUserFix = null;
    _lastUserFixAt = null;
    _userSpeedKmh = null;
    _userDistanceTravelledMeters = 0;
    _arrivalFixCount = 0;
    if (!mounted) return;
    setState(() {
      _trackingUser = false;
      _userPosition = null;
      _currentRoute = [];
      _routePolylines = {};
      _lastRouteOrigin = null;
      _lastRouteBusPosition = null;
      _routeUnavailable = false;
      _isRerouting = false;
      _routeEtaText = '';
      _routeRemainingKm = 0;
    });
    _refreshMapOverlays();
    _navigation.setSummary('', '');
    _updateNavigationTelemetry();
  }

  Widget _statusChip(String text, bool running) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: (running ? const Color(0xFF16A34A) : const Color(0xFF64748B))
          .withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: running ? const Color(0xFF15803D) : const Color(0xFF64748B),
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    ),
  );

  String _timeAgo(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 5) return 'just now';
    if (seconds < 60) return '${seconds}s ago';
    return '${seconds ~/ 60}m ago';
  }

  String _nextStopEta(BusLocation bus) {
    final target = _getHostelCoordinates(bus.assignedHostel);
    if (target == null) return 'timing unavailable';
    final km = _distanceKm(LatLng(bus.lat, bus.lng), target);
    final speed = bus.speed > 1 ? bus.speed : 20.0;
    return '${(km / speed * 60).ceil()} min';
  }

  Future<void> _callDriver(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (phone.isEmpty || !await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Driver contact is unavailable.')),
        );
      }
    }
  }

  void _changeZoom(double delta) {
    final selected = _findByKey(_fleet, _selectedBusKey);
    final target =
        _mapTarget ??
        (selected == null
            ? _defaultCenter
            : LatLng(selected.lat, selected.lng));
    _mapZoom = (_mapZoom + delta).clamp(_minZoom, _maxZoom);
    _moveCameraTo(target, zoom: _mapZoom);
  }

  void _refreshMapOverlays() {
    final markers = <Marker>{};
    final circles = <Circle>{};
    if (_userPosition != null) {
      final accuracy = _userAccuracyMeters.isFinite ? _userAccuracyMeters : 0.0;
      final clampedAccuracy = accuracy.clamp(0.0, 25.0);
      if (accuracy > 0 && accuracy <= 25) {
        circles.add(
          Circle(
            circleId: const CircleId('user_accuracy'),
            center: _userPosition!,
            radius: clampedAccuracy,
            fillColor: const Color(0x332563EB),
            strokeColor: const Color(0x662563EB),
            strokeWidth: 1,
          ),
        );
      }
    }
    for (final entry in _stopDefinitions.entries) {
      final data = entry.value;
      final point = LatLng(
        (data['lat'] as num).toDouble(),
        (data['lng'] as num).toDouble(),
      );
      circles.add(
        Circle(
          circleId: CircleId('stop_hit_${entry.key}'),
          center: point,
          radius: 110,
          fillColor: Colors.transparent,
          strokeColor: Colors.transparent,
          onTap: () => _chooseStop(entry.key),
        ),
      );
      circles.add(
        Circle(
          circleId: CircleId('stop_dot_${entry.key}'),
          center: point,
          radius: 24,
          fillColor: const Color(0xFF2563EB),
          strokeColor: Colors.white,
          strokeWidth: 3,
          onTap: () => _chooseStop(entry.key),
        ),
      );
    }
    for (final bus in _fleet) {
      final key = _busKey(bus.busId);
      final point = _animatedPositions[key] ?? LatLng(bus.lat, bus.lng);
      if (_selectedBusKey == key) {
        markers.add(
          Marker(
            markerId: MarkerId('bus_$key'),
            position: point,
            rotation: _animatedHeadings[key] ?? bus.heading,
            alpha: _running(bus) && !_isStale(bus)
                ? (_pulseExpanded ? 1 : .68)
                : 1,
            icon: _isStale(bus)
                ? BitmapDescriptor.defaultMarker
                : BitmapDescriptor.defaultMarkerWithHue(
                    _running(bus)
                        ? BitmapDescriptor.hueAzure
                        : (_navigation.mode == MapMode.routePreview
                              ? BitmapDescriptor.hueRed
                              : BitmapDescriptor.hueGreen),
                  ),
            anchor: const Offset(.5, .5),
            onTap: () => _showBusDetails(bus),
            infoWindow: InfoWindow(title: bus.busId),
          ),
        );
      } else {
        markers.addAll(
          PulsingDotMarker.build(
            id: 'bus_$key',
            position: point,
            running: _running(bus),
            expanded: _pulseExpanded,
            onTap: () => _chooseBus(bus),
          ),
        );
      }
    }
    if (_searchedPlacePosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('searched_place'),
          position: _searchedPlacePosition!,
          infoWindow: InfoWindow(title: _searchedPlaceName ?? 'Search result'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      );
    }
    if (_userPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('user'),
          position: _animatedPositions['user'] ?? _userPosition!,
          rotation: _userHeading,
          flat: true,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
          zIndexInt: 10,
        ),
      );
    }
    if (_navigation.mode == MapMode.routePreview && _currentRoute.length > 1) {
      markers.add(
        Marker(
          markerId: const MarkerId('route_eta'),
          position: _currentRoute[_currentRoute.length ~/ 2],
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
          infoWindow: InfoWindow(title: _routeEtaText),
        ),
      );
    }

    final mapType = _mapType;
    final mapStyle =
        mapType != MapType.satellite &&
            (_navigation.mode == MapMode.navigating ||
                _selectedMapLayer == MapLayer.dark ||
                DateTime.now().hour >= 18)
        ? _darkMapStyle
        : null;
    _mapOverlays.update(
      _MapOverlaySnapshot(
        markers: markers,
        circles: circles,
        polylines: _routePolylines,
        mapType: mapType,
        mapStyle: mapStyle,
        myLocationEnabled: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _findByKey(_fleet, _selectedBusKey);
    final currentUser = context.watch<AuthService>().currentUser;
    final driverSchedule = currentUser?.role == 'driver'
        ? context
              .watch<BusService>()
              .schedules
              .where(
                (s) =>
                    s.busNumber == currentUser?.busNumber &&
                    s.date.startsWith(
                      DateTime.now().toString().substring(0, 10),
                    ),
              )
              .firstOrNull
        : null;
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      body: Stack(
        children: [
          ChangeNotifierProvider<_MapOverlayNotifier>.value(
            value: _mapOverlays,
            child: Selector<_MapOverlayNotifier, _MapOverlaySnapshot>(
              selector: (_, overlays) => overlays.snapshot,
              builder: (context, overlays, _) => GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: selected == null
                      ? _defaultCenter
                      : LatLng(selected.lat, selected.lng),
                  zoom: _mapZoom,
                ),
                mapType: overlays.mapType,
                style: overlays.mapStyle,
                markers: overlays.markers,
                circles: overlays.circles,
                polylines: overlays.polylines,
                myLocationEnabled: overlays.myLocationEnabled,
                myLocationButtonEnabled: false,
                mapToolbarEnabled: false,
                minMaxZoomPreference: const MinMaxZoomPreference(
                  _minZoom,
                  _maxZoom,
                ),
                rotateGesturesEnabled: true,
                tiltGesturesEnabled: false,
                onMapCreated: _onMapCreated,
                onCameraMove: (position) {
                  _mapZoom = position.zoom.clamp(_minZoom, _maxZoom);
                  _mapTarget = position.target;
                },
                onCameraMoveStarted: () {
                  if (_navigation.mode == MapMode.navigating &&
                      !_cameraCommandActive) {
                    _navigationCameraTimer?.cancel();
                    _pendingNavigationCameraTarget = null;
                    _navigation.setFollowing(false);
                  }
                },
                onTap: (_) {
                  _searchFocusNode.unfocus();
                  setState(() => _suggestions = []);
                },
              ),
            ),
          ),
          if (currentUser?.role == 'driver')
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 92,
              child: Card(
                elevation: 5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.assignment, color: Color(0xFF1565C0)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          driverSchedule == null
                              ? 'Your bus ${currentUser?.busNumber ?? '—'} has no schedule today'
                              : 'Your Bus ${driverSchedule.busNumber} • ${driverSchedule.fromHostelTime} • ${currentUser?.hostelId ?? 'Hostel'} → MBSE',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_navigation.mode == MapMode.browse)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.paddingOf(context).top + 12,
              child: BusSearchBar(
                controller: _searchController,
                focusNode: _searchFocusNode,
                connected: _isConnected,
                refreshing: _isRefreshing,
                onChanged: _onSearchChanged,
                onSubmitted: _handleSearchQuery,
                onMenu: _toggleFleetPanel,
                onRefresh: _handleRefresh,
                suggestions: _suggestionDropdown(),
              ),
            ),
          if (_navigation.mode == MapMode.routePreview &&
              selected != null &&
              _userPosition != null)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.paddingOf(context).top + 8,
              child: RoutePreviewCard(
                origin: 'Your location',
                destination: selected.busId,
                onChangeDestination: _showSearch,
                onSwap: null,
                onMore: _showLayerChooser,
              ),
            ),
          if (_navigation.mode == MapMode.navigating)
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.paddingOf(context).top + 8,
              child: NavigationBanner(
                maneuver: _maneuvers.isEmpty
                    ? null
                    : _maneuvers[_maneuverIndex.clamp(
                        0,
                        _maneuvers.length - 1,
                      )],
                distance: _poorGpsAccuracy
                    ? 'Weak GPS · accuracy ${_userAccuracyMeters.round()} m'
                    : _nextTurnDistance(),
                rerouting: _isRerouting,
                routeUnavailable: _routeUnavailable,
                telemetry: _navigationTelemetry,
              ),
            ),
          if (_navigation.mode != MapMode.navigating && _isFleetPanelOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleFleetPanel,
                child: Container(color: Colors.black26),
              ),
            ),
          if (_navigation.mode != MapMode.navigating)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              left: _isFleetPanelOpen ? 0 : -330,
              top: 0,
              bottom: 0,
              width: 320,
              child: Material(
                color: theme.colorScheme.surface,
                elevation: 12,
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.directions_bus),
                        title: const Text(
                          'Campus buses',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        trailing: IconButton(
                          onPressed: _toggleFleetPanel,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      Expanded(
                        child: _isLoading && _fleet.isEmpty
                            ? const Center(child: CircularProgressIndicator())
                            : _fleet.isEmpty
                            ? const Center(
                                child: Text('No buses running right now'),
                              )
                            : ListView.builder(
                                itemCount: _fleet.length,
                                itemBuilder: (context, index) {
                                  final bus = _fleet[index];
                                  final running = _running(bus);
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 5,
                                    ),
                                    child: ListTile(
                                      leading: const CircleAvatar(
                                        child: Icon(Icons.directions_bus),
                                      ),
                                      title: Text(
                                        bus.busId,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${_routeLabel(bus)}\n${running ? 'Moving at ${bus.speed.toStringAsFixed(0)} km/h' : 'Parked'}',
                                      ),
                                      isThreeLine: true,
                                      trailing: _statusChip(
                                        running ? 'Running' : 'Idle',
                                        running,
                                      ),
                                      onTap: () {
                                        _toggleFleetPanel();
                                        _chooseBus(bus);
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_navigation.mode != MapMode.navigating)
            Positioned(
              right: 14,
              bottom: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Material(
                    color: Colors.white,
                    elevation: 5,
                    shadowColor: const Color(0x300F172A),
                    borderRadius: BorderRadius.circular(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _mapActionButton(
                          Icons.layers_rounded,
                          'Map layers',
                          _showLayerChooser,
                        ),
                        const Divider(height: 1, indent: 9, endIndent: 9),
                        _mapActionButton(
                          Icons.add_rounded,
                          'Zoom in',
                          () => _changeZoom(1),
                        ),
                        _mapActionButton(
                          Icons.remove_rounded,
                          'Zoom out',
                          () => _changeZoom(-1),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: Colors.white,
                    elevation: 5,
                    shadowColor: const Color(0x300F172A),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'My location',
                      onPressed: () {
                        final target =
                            _userPosition ??
                            (selected == null
                                ? _defaultCenter
                                : LatLng(selected.lat, selected.lng));
                        _moveCameraTo(target, zoom: 16);
                      },
                      icon: const Icon(
                        Icons.my_location_rounded,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_navigation.mode == MapMode.routePreview)
            Positioned(
              right: 16,
              top: MediaQuery.paddingOf(context).top + 70,
              child: FloatingActionButton.small(
                heroTag: 'preview_layers',
                onPressed: _showLayerChooser,
                child: const Icon(Icons.layers_outlined),
              ),
            ),
          if (_navigation.mode == MapMode.navigating)
            Positioned(
              right: 12,
              top: MediaQuery.sizeOf(context).height * .32,
              child: Column(
                children: [
                  _navControl(Icons.explore, 'Reset north', () {
                    _userHeading = 0;
                    _recenterUser();
                  }),
                  _navControl(Icons.search, 'Search', _showSearch),
                  _navControl(
                    _navigation.muted ? Icons.volume_off : Icons.volume_up,
                    'Toggle voice',
                    () => _navigation.toggleMute(),
                  ),
                  _navControl(Icons.map_outlined, 'Route overview', _fitRoute),
                ],
              ),
            ),
          if (_navigation.mode == MapMode.navigating && !_navigation.following)
            Positioned(
              left: 16,
              bottom: 110,
              child: FilledButton.icon(
                onPressed: _recenterUser,
                icon: const Icon(Icons.my_location),
                label: const Text('Re-centre'),
              ),
            ),
          if (_navigation.mode == MapMode.navigating)
            Positioned(
              right: 18,
              bottom: 112,
              child: ActionChip(
                label: const Text('Report'),
                onPressed: _reportIssue,
              ),
            ),
          if (_navigation.mode == MapMode.navigating)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: NavigationBottomBar(
                eta: _routeEtaText.isEmpty ? '--' : _routeEtaText,
                distance: _currentRoute.isEmpty
                    ? '--'
                    : _formatDistance(_routeRemainingKm * 1000),
                arrival: _arrivalClock(),
                travelled: _formatDistance(_userDistanceTravelledMeters),
                onEnd: _endNavigation,
                onShare: _shareEta,
              ),
            ),
          if (_navigation.mode == MapMode.arrived)
            Positioned(
              left: 20,
              right: 20,
              bottom: 100,
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: const Text('Arrived'),
                  trailing: TextButton(
                    onPressed: _endNavigation,
                    child: const Text('Done'),
                  ),
                ),
              ),
            ),
          if (!_isConnected && !_isLoading)
            Positioned(
              left: 12,
              right: 76,
              bottom: 20,
              child: Material(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$_connectionStatus · GPS fix ${_fleet.isEmpty ? 'unknown' : _timeAgo(_findByKey(_fleet, _selectedBusKey)?.timestamp ?? _fleet.first.timestamp)}'
                          '${_lastUpdate == null ? '' : ' · server last reached ${_timeAgo(_lastUpdate!)}'}'
                          '${_error == null ? '' : ' · $_error'}',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isSyncing
                            ? null
                            : () => _syncFleet(showToast: true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_isLoading && _fleet.isEmpty)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 68,
              left: 24,
              right: 24,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
          if (_isWaking)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 76,
              left: 20,
              right: 20,
              child: Card(
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Server is waking up, please wait...',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          if (!_isLoading && _fleet.isEmpty)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 72,
              left: 28,
              right: 28,
              child: Card(
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'No buses running right now',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          if (_trackingUser && _routeEtaText.isNotEmpty)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 76,
              left: 18,
              child: Chip(
                avatar: const Icon(Icons.route),
                label: Text(
                  '${_formatDistance(_routeRemainingKm * 1000)} · $_routeEtaText',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _suggestionDropdown() {
    if (_suggestions.isEmpty) return null;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x260F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 5),
            children: _suggestions.map((suggestion) {
              final isBus = suggestion.startsWith('bus:');
              final isPlace = suggestion.startsWith('place:');
              final rawName = suggestion.substring(suggestion.indexOf(':') + 1);
              final placeParts = isPlace
                  ? rawName.split('|')
                  : const <String>[];
              final name = isPlace && placeParts.length == 2
                  ? placeParts[1]
                  : rawName;
              final bus = isBus
                  ? _fleet.cast<BusLocation?>().firstWhere(
                      (item) => item?.busId == name,
                      orElse: () => null,
                    )
                  : null;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -1),
                leading: Icon(
                  isBus ? Icons.directions_bus : Icons.place,
                  color: isBus
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF2563EB),
                ),
                title: Text(
                  isBus
                      ? '$name · ${bus != null && _running(bus) ? 'Running · ${bus.speed.toStringAsFixed(0)} km/h' : 'Parked'}'
                      : name,
                ),
                onTap: () => isBus
                    ? (bus == null ? null : _chooseBus(bus))
                    : isPlace && placeParts.length == 2
                    ? _choosePlace(placeParts[0], placeParts[1])
                    : _chooseStop(name),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  double _distanceToRouteMeters(LatLng point, List<LatLng> path) {
    var minDistance = double.infinity;
    for (var index = 0; index < path.length - 1; index++) {
      final start = path[index];
      final end = path[index + 1];
      final meanLat = (start.latitude + end.latitude + point.latitude) / 3;
      final scaleX = cos(meanLat * pi / 180);
      final ax = start.longitude * scaleX;
      final ay = start.latitude;
      final bx = end.longitude * scaleX;
      final by = end.latitude;
      final px = point.longitude * scaleX;
      final py = point.latitude;
      final dx = bx - ax;
      final dy = by - ay;
      final lengthSquared = dx * dx + dy * dy;
      final t = lengthSquared == 0
          ? 0.0
          : (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
      final nearest = LatLng(ay + dy * t, (ax + dx * t) / scaleX);
      minDistance = min(minDistance, _distanceKm(point, nearest) * 1000);
    }
    return minDistance;
  }

  String _formatDistance(double meters) => meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';

  String _nextTurnDistance() {
    if (_userPosition == null || _maneuvers.isEmpty) return '';
    final maneuver = _maneuvers[_maneuverIndex.clamp(0, _maneuvers.length - 1)];
    final meters = (_distanceKm(_userPosition!, maneuver.point) * 1000).round();
    return meters < 1000
        ? '$meters m'
        : '${(meters / 1000).toStringAsFixed(1)} km';
  }

  Widget _mapActionButton(IconData icon, String tooltip, VoidCallback onTap) =>
      SizedBox(
        width: 48,
        height: 46,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, size: 22, color: const Color(0xFF334155)),
        ),
      );

  Widget _navControl(IconData icon, String tooltip, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: const Color(0xCC111827),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: tooltip,
            onPressed: onTap,
            color: Colors.white,
            icon: Icon(icon),
          ),
        ),
      );

  void _showSearch() {
    _navigation.browse();
    _searchFocusNode.requestFocus();
  }

  Future<void> _animateNavigationCamera(
    LatLng position, {
    bool immediate = false,
  }) async {
    _pendingNavigationCameraTarget = position;
    _navigationCameraTimer?.cancel();
    if (!immediate) {
      _navigationCameraTimer = Timer(
        const Duration(milliseconds: 350),
        _flushNavigationCamera,
      );
      return;
    }
    await _flushNavigationCamera();
  }

  void _queueNavigationCamera(LatLng position) {
    _pendingNavigationCameraTarget = position;
    if (_navigationCameraAnimating ||
        _navigationCameraTimer?.isActive == true) {
      return;
    }
    _navigationCameraTimer = Timer(
      const Duration(milliseconds: 350),
      _flushNavigationCamera,
    );
  }

  Future<void> _flushNavigationCamera() async {
    if (!_mapController.isCompleted ||
        _navigationCameraAnimating ||
        !_navigation.following ||
        _navigation.mode != MapMode.navigating) {
      return;
    }
    final position = _pendingNavigationCameraTarget ?? _userPosition;
    if (position == null) return;
    _pendingNavigationCameraTarget = null;
    _navigationCameraAnimating = true;
    _cameraCommandActive = true;
    try {
      final map = await _mapController.future;
      final radians = _userHeading * pi / 180;
      const lookAheadMeters = 40.0;
      final target = LatLng(
        position.latitude + cos(radians) * lookAheadMeters / 111320,
        position.longitude +
            sin(radians) *
                lookAheadMeters /
                (111320 * cos(position.latitude * pi / 180)),
      );
      _lastCameraBearing = _userHeading;
      await map.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _clampToCampus(target),
            zoom: 18,
            tilt: 45,
            bearing: _lastCameraBearing,
          ),
        ),
      );
    } finally {
      _cameraCommandActive = false;
      _navigationCameraAnimating = false;
      final latest = _pendingNavigationCameraTarget;
      if (latest != null &&
          _navigation.following &&
          _navigation.mode == MapMode.navigating) {
        _queueNavigationCamera(latest);
      }
    }
  }

  void _recenterUser() {
    _navigation.setFollowing(true);
    final user = _userPosition;
    if (user == null || !_mapController.isCompleted) return;
    _animateNavigationCamera(user, immediate: true);
  }

  void _fitRoute() {
    if (_currentRoute.length < 2 || !_mapController.isCompleted) return;
    final points = _currentRoute;
    final bounds = LatLngBounds(
      southwest: LatLng(
        points.map((p) => p.latitude).reduce(min),
        points.map((p) => p.longitude).reduce(min),
      ),
      northeast: LatLng(
        points.map((p) => p.latitude).reduce(max),
        points.map((p) => p.longitude).reduce(max),
      ),
    );
    _mapController.future.then(
      (map) => map.animateCamera(CameraUpdate.newLatLngBounds(bounds, 90)),
    );
  }

  String _arrivalClock() {
    final minutes = int.tryParse(_routeEtaText.split(' ').first);
    if (minutes == null) return 'ETA unavailable';
    return TimeOfDay.fromDateTime(
      DateTime.now().add(Duration(minutes: minutes)),
    ).format(context);
  }

  Future<void> _showLayerChooser() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Map type')),
          for (final layer in MapLayer.values)
            ListTile(
              title: Text(switch (layer) {
                MapLayer.street => 'Default',
                MapLayer.dark => 'Dark',
                MapLayer.satellite => 'Satellite',
                MapLayer.terrain => 'Terrain',
              }),
              trailing: _selectedMapLayer == layer
                  ? const Icon(Icons.check, color: Color(0xFF2563EB))
                  : null,
              onTap: () {
                setState(() => _selectedMapLayer = layer);
                _refreshMapOverlays();
                Navigator.pop(context);
              },
            ),
        ],
      ),
    ),
  );
}
