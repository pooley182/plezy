import 'dart:ui' as ui;

import 'package:flutter/services.dart';

typedef AppExitApplication = Future<ui.AppExitResponse> Function(ui.AppExitType exitType, int exitCode);

class AppExitService {
  static const MethodChannel _channel = MethodChannel('com.plezy/app_exit');

  /// Requests that the host platform closes or backgrounds the app.
  static Future<bool> requestExit({AppExitApplication? exitApplicationForTesting}) async {
    try {
      return await _channel.invokeMethod<bool>('requestExit') ?? true;
    } on MissingPluginException {
      await SystemNavigator.pop();
      return true;
    } on PlatformException {
      await SystemNavigator.pop();
      return true;
    }
  }
}
