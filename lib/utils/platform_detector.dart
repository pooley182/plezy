import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'async_singleton.dart';
import 'device_channel.dart';

const _androidFeatureTelevision = 'android.hardware.type.television';
const _androidFeatureLeanback = 'android.software.leanback';
const _androidFeatureFireTv = 'amazon.hardware.fire_tv';
const _androidFeatureTouchscreen = 'android.hardware.touchscreen';
const _androidFeatureAutomotive = 'android.hardware.type.automotive';

class AndroidTvFeatureDetection {
  final bool isTv;

  /// True on Android Automotive OS head units. Never true together with
  /// [isTv]: `FEATURE_AUTOMOTIVE` is authoritative for the car form factor.
  final bool isAutomotive;

  /// Diagnostic TV signals, surfaced in the log export only while TV mode is
  /// active. Non-empty with [isTv] false when automotive vetoed the verdict.
  final List<String> reasons;

  const AndroidTvFeatureDetection({required this.isTv, required this.isAutomotive, required this.reasons});
}

AndroidTvFeatureDetection detectAndroidTvFromSystemFeatures(Iterable<String> features) {
  final featureSet = features.toSet();
  final reasons = <String>[];
  if (featureSet.contains(_androidFeatureTelevision)) reasons.add('television_feature');
  if (featureSet.contains(_androidFeatureLeanback)) reasons.add('leanback');
  if (featureSet.contains(_androidFeatureFireTv)) reasons.add('fire_tv');
  if (featureSet.isNotEmpty && !featureSet.contains(_androidFeatureTouchscreen)) reasons.add('no_touchscreen');

  // A car is never a TV. Rotary-only head units report no touchscreen, and OEM
  // images derived from other AOSP variants can carry a stray leanback flag;
  // either would otherwise route a vehicle through the leanback experience.
  final isAutomotive = featureSet.contains(_androidFeatureAutomotive);

  return AndroidTvFeatureDetection(
    isTv: !isAutomotive && reasons.isNotEmpty,
    isAutomotive: isAutomotive,
    reasons: reasons,
  );
}

/// Whether a floating player may be offered for the detected form factor.
///
/// Cars commonly lack `FEATURE_PICTURE_IN_PICTURE`, and a floating player would
/// keep the app's UI on screen while driving, which `DD-2` forbids. TV form
/// factors have no windowed surface to float into.
bool pictureInPictureAllowed({required bool isTv, required bool isAutomotive}) => !isTv && !isAutomotive;

/// Service for detecting if the app is running on Android TV.
class TvDetectionService {
  static final AsyncSingleton<TvDetectionService> _singleton = AsyncSingleton();
  @visibleForTesting
  static set debugDetectionGate(Future<void>? value) => _singleton.debugGate = value;
  static bool? _debugTvOverride;
  static bool? _debugAutomotiveOverride;
  bool _detected = false;
  bool _forceTv = false;
  bool _isAutomotive = false;
  bool _initialized = false;
  List<String> _detectionReasons = const [];

  TvDetectionService._();

  /// Get the singleton instance, initializing if needed.
  /// Pass [forceTv] to combine a user override with the system-feature check.
  static Future<TvDetectionService> getInstance({bool forceTv = false}) =>
      _singleton.getInstance(TvDetectionService._, (instance) => instance._detect(forceTv));

  Future<void> _detect(bool forceTv) async {
    if (_initialized) return;

    final deviceInfo = DeviceInfoPlugin();
    final nativeDetection = await _getNativeAndroidTvDetection();
    final detection =
        nativeDetection ?? detectAndroidTvFromSystemFeatures((await deviceInfo.androidInfo).systemFeatures);
    _detected = detection.isTv;
    _isAutomotive = detection.isAutomotive;
    _detectionReasons = detection.reasons;
    _forceTv = forceTv;
    _initialized = true;
  }

  bool get isTV => _detected || _forceTv;

  /// True on Android Automotive OS. Independent of the force-TV override so
  /// driver-distraction gating cannot be switched off from settings.
  bool get isAutomotive => _isAutomotive;

  List<String> get _effectiveDetectionReasons {
    final reasons = <String>[..._detectionReasons];
    if (_forceTv && !reasons.contains('force_tv')) reasons.add('force_tv');
    return reasons;
  }

  Future<AndroidTvFeatureDetection?> _getNativeAndroidTvDetection() async {
    try {
      final result = await deviceChannel.invokeMapMethod<dynamic, dynamic>('getTvDetection');
      if (result == null) return null;
      final reasonsValue = result['reasons'];
      final reasons = reasonsValue is Iterable ? reasonsValue.whereType<String>().toList() : <String>[];
      final isTv = result['isTv'] == true;
      final isAutomotive = result['isAutomotive'] == true;
      if (isTv && reasons.isEmpty) reasons.add('native');
      return AndroidTvFeatureDetection(isTv: isTv && !isAutomotive, isAutomotive: isAutomotive, reasons: reasons);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// User-assigned Android device name (Settings > About > Device name), or
  /// null if unavailable.
  static Future<String?> getAndroidDeviceName() async {
    try {
      final name = (await deviceChannel.invokeMethod<String>('getDeviceName'))?.trim();
      return (name == null || name.isEmpty) ? null : name;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Update the user force-TV override; [isTV] reflects it immediately.
  void setForceTv(bool value) {
    _forceTv = value;
  }

  /// Synchronous access after initialization (returns false if not initialized).
  ///
  /// App code goes through the [PlatformDetector] facade ([PlatformDetector.isTV]
  /// and siblings); these raw accessors exist for the facade and tests.
  static bool isTVSync() => _debugTvOverride ?? _singleton.instance?.isTV ?? false;

  /// Synchronous TV-hardware check: [isTVSync] without the user's force-TV
  /// override (false before initialization).
  static bool isTVDeviceSync() => _debugTvOverride ?? _singleton.instance?._detected ?? false;

  /// Synchronous Android Automotive OS check (false before initialization).
  static bool isAutomotiveSync() => _debugAutomotiveOverride ?? _singleton.instance?._isAutomotive ?? false;

  /// Test-only: force [isTVSync] and [isTVDeviceSync].
  @visibleForTesting
  static void debugSetTvOverride(bool? value) {
    _debugTvOverride = value;
  }

  @visibleForTesting
  static void debugSetAutomotiveOverride(bool? value) {
    _debugAutomotiveOverride = value;
  }

  @visibleForTesting
  static void debugReset() {
    _singleton.debugReset();
    _debugTvOverride = null;
    _debugAutomotiveOverride = null;
  }

  static List<String> tvDetectionReasonsSync() => _singleton.instance?._effectiveDetectionReasons ?? const [];

  /// Convenience setter that forwards to the singleton if available.
  static void setForceTVSync(bool value) => _singleton.instance?.setForceTv(value);
}

class PlatformDetector {
  static bool isTV() {
    return TvDetectionService.isTVSync();
  }

  /// Whether the device itself is a TV, ignoring the force-TV layout setting.
  /// For what the system draws, such as the launcher; [isTV] decides the app's
  /// own layout.
  static bool isTVDevice() {
    return TvDetectionService.isTVDeviceSync();
  }

  /// True on Android Automotive OS head units.
  static bool isAutomotive() {
    return TvDetectionService.isAutomotiveSync();
  }

  /// Whether the app should use side navigation (TV).
  static bool shouldUseSideNavigation(BuildContext context) {
    return isDesktop(context);
  }

  /// Mobile shell in landscape: the bottom navigation bar becomes a leading
  /// [NavigationRail] so a wide, short viewport — a rotated phone, a car head
  /// unit — keeps its height for content. Not the desktop/TV sidebar: every
  /// other mobile layout decision stays as it is.
  static bool shouldUseLandscapeNavigationRail(BuildContext context) {
    return isMobile(context) && MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  /// Whether this device should act as a companion remote host (receiver).
  /// Android TV is a host; phones/tablets are controllers.
  static bool shouldActAsRemoteHost(BuildContext context) {
    return isDesktop(context);
  }

  /// Whether this is a phone or tablet rather than a TV.
  static bool isMobile(BuildContext context) {
    return !isTV();
  }

  /// The inverse of [isMobile]: TV.
  static bool isDesktop(BuildContext context) {
    return !isMobile(context);
  }

  /// Audio passthrough to an HDMI receiver; Android TV only.
  static bool supportsAudioPassthrough() => isTV();

  static bool supportsPictureInPicture() => pictureInPictureAllowed(isTv: isTV(), isAutomotive: isAutomotive());

  /// Detects if the device is likely a tablet based on screen size
  /// Uses diagonal screen size to determine if device is a tablet
  static bool isTablet(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final diagonal = sqrt(size.width * size.width + size.height * size.height);

    // Logical pixels are density-independent at ~160 per inch, so the diagonal
    // converts to inches directly; devicePixelRatio is already factored out.
    final diagonalInches = diagonal / 160.0;

    return diagonalInches >= 7.0;
  }

  static bool isPhone(BuildContext context) {
    return isMobile(context) && !isTablet(context);
  }
}
