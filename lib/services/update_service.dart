import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Service that wraps [ShorebirdUpdater] for OTA code push updates.
///
/// Handles the case where the app is NOT running inside a Shorebird-built
/// release (e.g. debug mode) — all methods are no-ops in that case.
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  final ShorebirdUpdater _updater = ShorebirdUpdater();

  /// Whether Shorebird is available in this build.
  bool get isAvailable => _updater.isAvailable;

  /// Returns the current patch number, or `null` if no patch is installed
  /// or Shorebird is not available.
  Future<int?> getCurrentPatchNumber() async {
    if (!isAvailable) return null;
    try {
      final patch = await _updater.readCurrentPatch();
      return patch?.number;
    } catch (e) {
      debugPrint('UpdateService: Failed to read current patch: $e');
      return null;
    }
  }

  /// Checks whether a new patch is available.
  ///
  /// Returns [UpdateStatus.upToDate] if no update or Shorebird is unavailable.
  Future<UpdateStatus> checkForUpdate() async {
    if (!isAvailable) return UpdateStatus.upToDate;
    try {
      return await _updater.checkForUpdate();
    } catch (e) {
      debugPrint('UpdateService: Failed to check for update: $e');
      return UpdateStatus.upToDate;
    }
  }

  /// Downloads and stages the latest patch.
  ///
  /// The patch will be applied on the next app restart.
  /// Returns `true` if the update was downloaded successfully.
  Future<bool> performUpdate() async {
    if (!isAvailable) return false;
    try {
      await _updater.update();
      return true;
    } on UpdateException catch (e) {
      debugPrint('UpdateService: Update failed: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('UpdateService: Unexpected error during update: $e');
      return false;
    }
  }

  /// Convenience: checks for update and downloads it if available.
  ///
  /// Returns `true` if an update was downloaded and is pending restart.
  Future<bool> checkAndUpdate() async {
    final status = await checkForUpdate();
    if (status == UpdateStatus.outdated) {
      return await performUpdate();
    }
    return false;
  }
}
