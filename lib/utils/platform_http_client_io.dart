import 'dart:io' show HttpClient, Platform;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_logger.dart';
import 'happy_eyeballs.dart';
import 'managed_http_client.dart';
import 'media_server_timeouts.dart';

final Set<String> _loggedPlatformClients = <String>{};

void _logPlatformClient(String platform, String client) {
  if (!_loggedPlatformClients.add(client)) return;
  appLogger.i('Platform HTTP client', error: {'platform': platform, 'client': client});
}

/// dart:io leaves TCP connects unbounded (Darwin retries SYNs for ~75 s) and
/// `package:http` cannot abort a request whose connection is still being
/// established, so every IOClient gets an explicit connect bound and
/// permission to force-close after a failed drain (#1972). The bound covers
/// only reaching the server: `Client.send` then waits for response headers,
/// which is the server's think time and the caller's deadline to set.
///
/// The pool is always widened. Every surface that matters fans out — Plex and
/// Jellyfin home loads, artwork rails, tracker and Seerr traffic all issue
/// several concurrent requests per pass — and dart:io's default of 6
/// connections per host queues them. On a 60-way artwork fan-out, 12
/// connections measured ~2x the default's throughput on Android.
///
/// The idle timeout has to stay below the server's keep-alive, because dart:io
/// never resends a request that fails on a reused connection
/// (dart-lang/sdk#21798). Plex sends `Keep-Alive: timeout=20`, and over TLS it
/// stops answering an idle connection at 20 s but closes it only ~3 s later.
/// Every request the pool hands that connection in between fails with
/// "Connection closed before full header was received"; at 90 s that blanked
/// whole rows of posters (#2670). Retiring connections at 15 s, before Plex
/// does, costs a handshake only after a lull, never inside a fan-out.
ManagedHttpClient _createIoClient(String debugLabel, Duration connectTimeout) {
  final httpClient = HttpClient()
    ..connectionTimeout = connectTimeout
    ..maxConnectionsPerHost = 12
    ..idleTimeout = const Duration(seconds: 15)
    ..connectionFactory = happyEyeballsConnectionFactory;
  return ManagedHttpClient(IOClient(httpClient), debugLabel: debugLabel, forceCloseOnDrainTimeout: true);
}

/// The tuned dart:io client.
///
/// Cronet used to serve Android here, but was measured ~10x slower on LAN body
/// throughput for the request shapes Plezy issues; see issue #2140.
///
/// Only the connect is bounded, to [connectTimeout]. Waiting on the server is
/// left to the caller's deadlines (#2581).
http.Client createPlatformClient({Duration connectTimeout = MediaServerTimeouts.connect}) {
  _logPlatformClient(Platform.operatingSystem, 'IOClient');
  return _createIoClient('IOClient', connectTimeout);
}
