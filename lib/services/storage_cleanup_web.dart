/// Web stub: no file system, so nothing is left behind to clean up.
class StorageCleanup {
  StorageCleanup._();
  static final StorageCleanup instance = StorageCleanup._();

  Future<void> deleteScratch(String? path) async {}
  void scheduleLaunchSweep() {}
}
