class MP {
  /// Returns the Mapbox token from the environment, a compile-time
  /// `--dart-define=MAPBOX_TOKEN=...`, or an empty string.
  ///
  /// Compile-time defines keep local credentials out of bundled assets.
  static String get mapboxToken {
    const dartDefine = String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;

    return '';
  }

  static String get googleMapsApiKey {
    const dartDefine = String.fromEnvironment(
      'GOOGLE_MAPS_API_KEY',
      defaultValue: '',
    );
    if (dartDefine.isNotEmpty) return dartDefine;

    const mapsDefine = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
    if (mapsDefine.isNotEmpty) return mapsDefine;

    return '';
  }

  /// Returns a generic Leaflet-compatible tile provider token (e.g. MapTiler).
  /// Use `--dart-define=LEAFLET_TOKEN=...`.
  static String get leafletToken {
    const dartDefine = String.fromEnvironment(
      'LEAFLET_TOKEN',
      defaultValue: '',
    );
    if (dartDefine.isNotEmpty) return dartDefine;

    return '';
  }
}
