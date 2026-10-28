import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:campus_bus_tracker/services/authenticated_stream_coordinator.dart';

void main() {
  test(
    'logout cancels the active stream and prevents pending reconnects',
    () async {
      var connections = 0;
      final source = StreamController<int>();
      final coordinator = AuthenticatedStreamCoordinator<int>((_) {
        connections++;
        return source.stream;
      });
      final subscription = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});

      await Future<void>.delayed(Duration.zero);
      coordinator.cancel('session-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(connections, 1);
      expect(source.hasListener, isFalse);
      await subscription.cancel();
    },
  );

  test('expired session is not connected', () async {
    var connections = 0;
    final coordinator = AuthenticatedStreamCoordinator<int>((_) {
      connections++;
      return Stream<int>.empty();
    });
    final subscription = coordinator
        .subscribe(
          'expired-session',
          isSessionValid: () => false,
          onUnauthorized: () async {},
        )
        .listen((_) {});

    await Future<void>.delayed(Duration.zero);

    expect(connections, 0);
    await subscription.cancel();
  });

  test(
    '401 stops reconnects and invokes the session-expiration callback',
    () async {
      var connections = 0;
      var expired = 0;
      final coordinator = AuthenticatedStreamCoordinator<int>((_) {
        connections++;
        return Stream<int>.error(const StreamUnauthorizedException());
      });
      final subscription = coordinator
          .subscribe(
            'expired-session',
            isSessionValid: () => true,
            onUnauthorized: () async {
              expired++;
            },
          )
          .listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(connections, 1);
      expect(expired, 1);
      await subscription.cancel();
    },
  );

  test(
    'temporary connection failure retains exponential reconnect behavior',
    () async {
      var connections = 0;
      final received = Completer<int>();
      final coordinator = AuthenticatedStreamCoordinator<int>((_) {
        connections++;
        if (connections == 1) return Stream<int>.error(Exception('offline'));
        return Stream<int>.value(42);
      });
      final subscription = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((value) {
            if (!received.isCompleted) received.complete(value);
          });

      expect(await received.future.timeout(const Duration(seconds: 3)), 42);
      expect(connections, greaterThanOrEqualTo(2));
      await subscription.cancel();
    },
  );

  test(
    'disposing the last widget subscription closes the shared connection',
    () async {
      final source = StreamController<int>();
      final coordinator = AuthenticatedStreamCoordinator<int>(
        (_) => source.stream,
      );
      final subscription = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});

      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(source.hasListener, isFalse);
    },
  );

  test(
    'screens sharing one token share a single transport connection',
    () async {
      var connections = 0;
      final source = StreamController<int>();
      final coordinator = AuthenticatedStreamCoordinator<int>((_) {
        connections++;
        return source.stream;
      });
      final first = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});
      final second = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});

      await Future<void>.delayed(Duration.zero);
      expect(connections, 1);
      await first.cancel();
      expect(source.hasListener, isTrue);
      await second.cancel();
      expect(source.hasListener, isFalse);
    },
  );

  test(
    'switching accounts cancels the old connection before opening the new one',
    () async {
      final connections = <String>[];
      final oldSource = StreamController<int>();
      final coordinator = AuthenticatedStreamCoordinator<int>((token) {
        connections.add(token);
        return token == 'session-a' ? oldSource.stream : Stream<int>.empty();
      });
      final oldSubscription = coordinator
          .subscribe(
            'session-a',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);
      final newSubscription = coordinator
          .subscribe(
            'session-b',
            isSessionValid: () => true,
            onUnauthorized: () async {},
          )
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(connections, ['session-a', 'session-b']);
      expect(oldSource.hasListener, isFalse);
      await oldSubscription.cancel();
      await newSubscription.cancel();
    },
  );
}
