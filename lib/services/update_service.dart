import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Where the app is in the over-the-air update cycle.
///
/// Surfaced on the kiosk so whoever is standing at it can tell the difference
/// between "this device is current" and "this device is running code from
/// three patches ago" — which, until now, was invisible from the device and
/// only inferable from the dashboard.
enum AppUpdateState {
  /// Not a Shorebird release (debug/profile build) — nothing to report.
  unavailable,

  /// No check has completed yet this launch.
  unknown,

  /// Asking the server whether a newer patch exists.
  checking,

  /// Running the newest patch the server has.
  upToDate,

  /// A newer patch exists and is being pulled down.
  downloading,

  /// Downloaded and staged. Shorebird applies patches at launch, so this one
  /// needs a restart before it does anything.
  readyToRestart,

  /// The check or download failed. Distinct from upToDate on purpose: a
  /// kiosk that silently failed to update looks identical to a current one,
  /// which is how a fleet drifts without anyone noticing.
  failed,
}

/// Service that wraps [ShorebirdUpdater] for OTA code push updates.
///
/// Handles the case where the app is NOT running inside a Shorebird-built
/// release (e.g. debug mode) — all methods are no-ops in that case.
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  final ShorebirdUpdater _updater = ShorebirdUpdater();

  /// Single source of truth for update progress.
  ///
  /// A ValueNotifier rather than a return value because two places care about
  /// the same cycle: main() kicks the check off at launch, and the kiosk
  /// header displays it. Having each run its own check would download twice
  /// and let the two disagree about what state the device is in.
  final ValueNotifier<AppUpdateState> state =
      ValueNotifier<AppUpdateState>(AppUpdateState.unknown);

  /// Patch number currently running, or null if on the base release.
  final ValueNotifier<int?> currentPatch = ValueNotifier<int?>(null);

  /// Release version as "1.2.0+67", or null before it has been read.
  final ValueNotifier<String?> releaseVersion = ValueNotifier<String?>(null);

  /// Guards against two overlapping check/download cycles.
  bool _inFlight = false;

  /// Both network calls are bounded, because neither the check nor the
  /// download carries a timeout of its own.
  ///
  /// Without these a half-open connection — a captive portal, or the flaky
  /// office WiFi this kiosk actually lives on — leaves the await hanging
  /// forever. That would strand [state] on `checking`, so the header spins
  /// indefinitely and looks broken, and worse, leave [_inFlight] latched true
  /// for the life of the process, silently blocking every later check. A
  /// kiosk stays up for weeks, so "silently stops updating" is precisely the
  /// failure this whole indicator exists to make visible.
  static const _checkTimeout = Duration(seconds: 20);

  /// Generous: a patch is ~1 MB over clinic WiFi, and a download killed
  /// halfway just retries on the next cycle.
  static const _downloadTimeout = Duration(minutes: 5);

  /// Whether Shorebird is available in this build.
  bool get isAvailable => _updater.isAvailable;

  /// Populates [releaseVersion] and [currentPatch] for display. Safe to call
  /// repeatedly; cheap after the first read.
  Future<void> loadVersionInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      releaseVersion.value = '${info.version}+${info.buildNumber}';
    } catch (e) {
      debugPrint('UpdateService: failed to read package info: $e');
    }
    currentPatch.value = await getCurrentPatchNumber();
    if (!isAvailable) state.value = AppUpdateState.unavailable;
  }

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
      return await _updater.checkForUpdate().timeout(_checkTimeout);
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
      await _updater.update().timeout(_downloadTimeout);
      return true;
    } on UpdateException catch (e) {
      debugPrint('UpdateService: Update failed: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('UpdateService: Unexpected error during update: $e');
      return false;
    }
  }

  /// Checks for an update, downloads it if there is one, and drives [state]
  /// through the transitions the kiosk header renders.
  ///
  /// Returns `true` if an update was downloaded and is pending restart.
  /// Concurrent calls are collapsed: the second one returns immediately
  /// rather than starting a second download of the same patch.
  Future<bool> checkAndUpdate() async {
    if (!isAvailable) {
      state.value = AppUpdateState.unavailable;
      return false;
    }
    if (_inFlight) return false;
    _inFlight = true;

    try {
      // Keep a staged patch visible as such. Re-checking would report
      // upToDate — the download already happened — and the header would stop
      // asking for the restart that actually applies it.
      if (state.value == AppUpdateState.readyToRestart) return false;

      state.value = AppUpdateState.checking;
      final status = await checkForUpdate();

      if (status != UpdateStatus.outdated) {
        state.value = AppUpdateState.upToDate;
        return false;
      }

      state.value = AppUpdateState.downloading;
      final ok = await performUpdate();
      state.value = ok ? AppUpdateState.readyToRestart : AppUpdateState.failed;
      if (ok) currentPatch.value = await getCurrentPatchNumber();
      return ok;
    } catch (e) {
      debugPrint('UpdateService: update cycle failed: $e');
      state.value = AppUpdateState.failed;
      return false;
    } finally {
      _inFlight = false;
    }
  }
}
