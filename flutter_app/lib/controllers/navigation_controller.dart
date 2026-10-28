import 'package:flutter/foundation.dart';

enum MapMode { browse, routePreview, navigating, arrived }
enum RouteTravelMode { walk, bike, drive }

class NavigationController extends ChangeNotifier {
  MapMode _mode = MapMode.browse;
  RouteTravelMode _travelMode = RouteTravelMode.drive;
  bool _muted = false;
  bool _following = true;
  String _eta = '';
  String _distance = '';
  String get eta => _eta;
  String get distance => _distance;
  void setSummary(String eta, String distance) {
    if (_eta == eta && _distance == distance) return;
    _eta = eta; _distance = distance; notifyListeners();
  }
  MapMode get mode => _mode;
  RouteTravelMode get travelMode => _travelMode;
  bool get muted => _muted;
  bool get following => _following;
  void showPreview() { _mode = MapMode.routePreview; notifyListeners(); }
  void start() { _mode = MapMode.navigating; _following = true; notifyListeners(); }
  void arrive() { _mode = MapMode.arrived; notifyListeners(); }
  void setTravelMode(RouteTravelMode mode) { _travelMode = mode; notifyListeners(); }
  void toggleMute() { _muted = !_muted; notifyListeners(); }
  void setFollowing(bool value) { _following = value; notifyListeners(); }
  void browse() { _mode = MapMode.browse; _following = true; notifyListeners(); }
}
