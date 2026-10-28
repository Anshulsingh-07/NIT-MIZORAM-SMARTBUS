import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/route_model.dart';

enum NavigationState {
  idle,
  searching,
  routeLoading,
  routeReady,
  navigating,
  rerouting,
  arrived,
  error,
}

class MapNavigationController extends ChangeNotifier {
  NavigationState _state = NavigationState.idle;
  NavigationState get state => _state;

  RouteModel? _activeRoute;
  RouteModel? get activeRoute => _activeRoute;

  LatLng? _destination;
  LatLng? get destination => _destination;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  void setState(NavigationState s, {String? message}) {
    _state = s;
    _errorMessage = message;
    notifyListeners();
  }

  void setRoute(RouteModel? r, {LatLng? destination}) {
    _activeRoute = r;
    _destination = destination ?? _destination;
    if (r != null) {
      _state = NavigationState.routeReady;
    }
    notifyListeners();
  }

  void clear() {
    _activeRoute = null;
    _destination = null;
    _errorMessage = null;
    _state = NavigationState.idle;
    notifyListeners();
  }
}
