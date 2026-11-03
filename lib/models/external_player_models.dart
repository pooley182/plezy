import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

typedef PlayerLauncher = Future<bool> Function(String url);

enum CustomPlayerType { command, urlScheme }

class ExternalPlayer {
  final String id;
  final String name;
  final String? iconAsset;
  final bool isAvailable;
  final PlayerLauncher launch;

  final bool isCustom;
  final String? customValue; // Only for custom player serialization
  final CustomPlayerType? customType;

  ExternalPlayer({
    required this.id,
    required this.name,
    this.iconAsset,
    this.isAvailable = true,
    required this.launch,
    this.isCustom = false,
    this.customValue,
    this.customType,
  });

  factory ExternalPlayer.custom({
    required String id,
    required String name,
    required String value,
    required CustomPlayerType type,
  }) {
    return ExternalPlayer(
      id: id,
      name: name,
      isCustom: true,
      customValue: value,
      customType: type,
      launch: (url) => _launchCustom(value, url, type),
    );
  }

  factory ExternalPlayer.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final known = KnownPlayers.findById(id);
    if (known != null) return known;
    return ExternalPlayer.custom(
      id: id,
      name: json['name'] as String,
      value: json['customValue'] as String? ?? '',
      type: json['customType'] == 'urlScheme' ? CustomPlayerType.urlScheme : CustomPlayerType.command,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (isCustom) 'isCustom': true,
    if (customValue != null) 'customValue': customValue,
    if (customType != null) 'customType': customType == CustomPlayerType.urlScheme ? 'urlScheme' : 'command',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ExternalPlayer && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

Future<bool> _launchWithUrl(String url) {
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<bool> _launchAndroidIntent(String url, {required String package, bool fallbackToUrl = true}) async {
  final intentUri = Uri.parse(
    'intent:$url#Intent;'
    'action=android.intent.action.VIEW;'
    'type=video/*;'
    'package=$package;'
    'end',
  );
  try {
    return await launchUrl(intentUri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return fallbackToUrl ? _launchWithUrl(url) : false;
  }
}

Future<bool> _launchAndroidIntentCandidates(String url, Iterable<String> packages) async {
  for (final package in packages) {
    if (await _launchAndroidIntent(url, package: package, fallbackToUrl: false)) return true;
  }
  return _launchWithUrl(url);
}

Future<bool> _launchUrlScheme(String scheme, String url) {
  final playerUrl = scheme.contains('url=') ? '$scheme${Uri.encodeComponent(url)}' : '$scheme$url';
  return _openPlayerUri(Uri.parse(playerUrl));
}

Future<bool> _openPlayerUri(Uri uri) async {
  // Apple platforms skip the canOpenURL gate: it answers false for any scheme
  // missing from LSApplicationQueriesSchemes, which is every custom player.
  // The open call reports a missing handler itself.
  if (await canLaunchUrl(uri)) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  return false;
}

Future<bool> _launchCustom(String value, String url, CustomPlayerType type) async {
  if (type == CustomPlayerType.urlScheme) {
    return _launchUrlScheme(value, url);
  }
  // Command type
  return _launchAndroidIntent(url, package: value);
}

class KnownPlayers {
  /// Hands the stream URL to whatever the OS opens it with. tvOS has no
  /// browser or default handler for http(s), so there is nothing to hand to.
  static final systemDefault = ExternalPlayer(
    id: 'system_default',
    name: 'System Default',
    isAvailable: true,
    launch: _launchWithUrl,
  );

  static const _androidPackageMap = <String, List<String>>{
    'vlc': ['org.videolan.vlc'],
    'mpv': ['is.xyz.mpv'],
    'mx_player': ['com.mxtech.videoplayer.ad', 'com.mxtech.videoplayer.pro'],
    'just_player': ['com.brouken.player'],
  };

  static List<String> _androidPackageCandidatesForId(String id) {
    return _androidPackageMap[id] ?? const [];
  }

  static List<String> androidPackageCandidates(ExternalPlayer player) {
    final knownPackages = _androidPackageCandidatesForId(player.id);
    if (knownPackages.isNotEmpty) return knownPackages;
    if (player.isCustom && player.customType == CustomPlayerType.command) {
      final package = player.customValue?.trim();
      return package == null || package.isEmpty ? const [] : [package];
    }
    return const [];
  }

  static final _allPlayers = <ExternalPlayer>[
    systemDefault,
    ExternalPlayer(
      id: 'vlc',
      name: 'VLC',
      iconAsset: 'assets/player_icons/vlc.svg',
      isAvailable: true,
      launch: (url) {
        return _launchAndroidIntentCandidates(url, _androidPackageCandidatesForId('vlc'));
      },
    ),
    ExternalPlayer(
      id: 'mpv',
      name: 'mpv',
      iconAsset: 'assets/player_icons/mpv.svg',
      isAvailable: true,
      launch: (url) {
        return _launchAndroidIntentCandidates(url, _androidPackageCandidatesForId('mpv'));
      },
    ),
    ExternalPlayer(
      id: 'mx_player',
      name: 'MX Player',
      iconAsset: 'assets/player_icons/mx_player.svg',
      isAvailable: true,
      launch: (url) => _launchAndroidIntentCandidates(url, _androidPackageCandidatesForId('mx_player')),
    ),
    ExternalPlayer(
      id: 'just_player',
      name: 'Just Player',
      iconAsset: 'assets/player_icons/just_player.png',
      isAvailable: true,
      launch: (url) => _launchAndroidIntentCandidates(url, _androidPackageCandidatesForId('just_player')),
    ),
  ];

  static Future<List<ExternalPlayer>>? _installedPlayers;

  /// Players supported on this device, resolved once per process.
  static Future<List<ExternalPlayer>> getForCurrentPlatform() {
    return _installedPlayers ??= _resolveForCurrentPlatform();
  }

  @visibleForTesting
  static void resetForTesting() {
    _installedPlayers = null;
  }

  static Future<List<ExternalPlayer>> _resolveForCurrentPlatform() async => [
    for (final player in _allPlayers)
      if (player.isAvailable) player,
  ];

  static ExternalPlayer? findById(String id) {
    try {
      return _allPlayers.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}
