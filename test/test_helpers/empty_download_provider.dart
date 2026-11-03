import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';

/// A [DownloadProvider] with nothing downloaded, for widgets (media menus)
/// that only look one up. Disposed with the test.
DownloadProvider emptyDownloadProvider() {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final manager = DownloadManagerService(
    database: db,
    storageService: DownloadStorageService.instance,
    clientResolver: (serverId, {clientScopeId}) => null,
  )..recoveryFuture = Future<void>.value();
  final provider = DownloadProvider.forTesting(downloadManager: manager, database: db);
  addTearDown(() async {
    provider.dispose();
    manager.dispose();
    await db.close();
  });
  return provider;
}
