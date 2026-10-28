import 'dart:async';

class StreamUnauthorizedException implements Exception {
  const StreamUnauthorizedException();
}

class AuthenticatedStreamCoordinator<T> {
  AuthenticatedStreamCoordinator(this._connect);

  final Stream<T> Function(String token) _connect;
  _StreamSession<T>? _session;
  int _generation = 0;

  Stream<T> subscribe(
    String token, {
    required bool Function() isSessionValid,
    required FutureOr<void> Function() onUnauthorized,
  }) {
    if (token.isEmpty) return const Stream.empty();

    var session = _session;
    if (session == null || session.token != token || !session.active) {
      if (session != null) _stop(session, closeSubscribers: true);
      session = _StreamSession<T>(token, ++_generation);
      _session = session;
    }

    late final _StreamSubscriber<T> subscriber;
    final controller = StreamController<T>(
      sync: true,
      onListen: () => _start(session!),
      onCancel: () => _removeSubscriber(session!, subscriber),
    );
    subscriber = _StreamSubscriber<T>(
      controller,
      isSessionValid,
      onUnauthorized,
    );
    session.subscribers.add(subscriber);
    return controller.stream;
  }

  void cancel([String? token]) {
    final session = _session;
    if (session == null || (token != null && token != session.token)) return;
    _stop(session, closeSubscribers: true);
  }

  void _removeSubscriber(
    _StreamSession<T> session,
    _StreamSubscriber<T> subscriber,
  ) {
    session.subscribers.remove(subscriber);
    if (session.subscribers.isEmpty) _stop(session, closeSubscribers: false);
  }

  bool _isCurrent(_StreamSession<T> session) =>
      identical(_session, session) && session.active;

  bool _hasValidSubscriber(_StreamSession<T> session) {
    for (final subscriber in session.subscribers) {
      try {
        if (subscriber.isSessionValid()) return true;
      } catch (_) {
        // A disposed widget or provider must not keep the connection alive.
      }
    }
    return false;
  }

  void _start(_StreamSession<T> session) {
    if (!_isCurrent(session) || session.connecting || session.source != null)
      return;
    if (!_hasValidSubscriber(session)) {
      _stop(session, closeSubscribers: true);
      return;
    }
    session.retryTimer?.cancel();
    session.retryTimer = null;
    session.connecting = true;
    try {
      session.source = _connect(session.token).listen(
        (event) {
          if (!_isCurrent(session) || !_hasValidSubscriber(session)) return;
          session.retrySeconds = 1;
          for (final subscriber in List.of(session.subscribers)) {
            if (!subscriber.controller.isClosed)
              subscriber.controller.add(event);
          }
        },
        onError: (Object error, StackTrace stack) {
          session.source = null;
          session.connecting = false;
          if (!_isCurrent(session)) return;
          if (error is StreamUnauthorizedException) {
            _expire(session);
          } else {
            _scheduleRetry(session);
          }
        },
        onDone: () {
          session.source = null;
          session.connecting = false;
          if (_isCurrent(session)) _scheduleRetry(session);
        },
        cancelOnError: false,
      );
      session.connecting = false;
    } catch (_) {
      session.source = null;
      session.connecting = false;
      _scheduleRetry(session);
    }
  }

  void _scheduleRetry(_StreamSession<T> session) {
    if (!_isCurrent(session) || !_hasValidSubscriber(session)) {
      _stop(session, closeSubscribers: true);
      return;
    }
    if (session.retryTimer?.isActive == true) return;
    final delay = Duration(seconds: session.retrySeconds);
    session.retrySeconds = (session.retrySeconds * 2).clamp(1, 15).toInt();
    final generation = session.generation;
    session.retryTimer = Timer(delay, () {
      if (_isCurrent(session) && session.generation == generation)
        _start(session);
    });
  }

  void _expire(_StreamSession<T> session) {
    if (!_isCurrent(session)) return;
    session.active = false;
    session.retryTimer?.cancel();
    session.retryTimer = null;
    final source = session.source;
    session.source = null;
    if (source != null) unawaited(source.cancel());
    for (final subscriber in List.of(session.subscribers)) {
      unawaited(Future<void>.sync(subscriber.onUnauthorized));
      if (!subscriber.controller.isClosed)
        unawaited(subscriber.controller.close());
    }
  }

  void _stop(_StreamSession<T> session, {required bool closeSubscribers}) {
    if (!session.active && !closeSubscribers) return;
    session.active = false;
    session.retryTimer?.cancel();
    session.retryTimer = null;
    final source = session.source;
    session.source = null;
    session.connecting = false;
    if (source != null) unawaited(source.cancel());
    if (identical(_session, session)) _session = null;
    if (closeSubscribers) {
      for (final subscriber in List.of(session.subscribers)) {
        if (!subscriber.controller.isClosed)
          unawaited(subscriber.controller.close());
      }
      session.subscribers.clear();
    }
  }
}

class _StreamSession<T> {
  _StreamSession(this.token, this.generation);

  final String token;
  final int generation;
  final Set<_StreamSubscriber<T>> subscribers = {};
  StreamSubscription<T>? source;
  Timer? retryTimer;
  int retrySeconds = 1;
  bool connecting = false;
  bool active = true;
}

class _StreamSubscriber<T> {
  _StreamSubscriber(this.controller, this.isSessionValid, this.onUnauthorized);

  final StreamController<T> controller;
  final bool Function() isSessionValid;
  final FutureOr<void> Function() onUnauthorized;
}
