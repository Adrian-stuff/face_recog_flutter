import 'dart:async';
import 'package:flutter/material.dart';
import '../config/kiosk_config.generated.dart';
import '../services/supabase_service.dart';

/// The punch-confirmation dialog shown right after a time-in/out. Split out
/// of FaceScanScreen (a StatefulWidget in its own right, not a
/// StatefulBuilder like the sync-issues dialog) because it needs a real
/// dispose() hook to stop polling if the employee taps "Done" before the
/// bounded wait below resolves.
///
/// recordAttendance() is offline-first: the punch is saved locally and
/// reported as done before anyone knows whether it actually reached the
/// server. Showing the same "Recorded!" dialog either way was the gap that
/// let a punch silently fail to sync with no visible sign anything was
/// wrong — this dialog instead shows the real state: confirmed by the
/// server, still offline, or still trying.
class PunchConfirmationDialog extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String employeeName;
  final String timeString;
  final num similarity;
  final String? overtimeSubtitle;

  /// Whether the device had no network radio at all at the moment this
  /// punch was recorded — if so, there's no point polling for a server
  /// outcome that was never going to come.
  final bool recordedOffline;
  final String clientEventId;
  final Future<PunchSyncState> Function(String clientEventId)
  checkPunchSyncState;

  const PunchConfirmationDialog({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.employeeName,
    required this.timeString,
    required this.similarity,
    required this.overtimeSubtitle,
    required this.recordedOffline,
    required this.clientEventId,
    required this.checkPunchSyncState,
  });

  @override
  State<PunchConfirmationDialog> createState() =>
      _PunchConfirmationDialogState();
}

enum _SyncPhase { offline, confirming, confirmed, stillSyncing }

class _PunchConfirmationDialogState extends State<PunchConfirmationDialog> {
  static const _pollInterval = Duration(milliseconds: 400);
  static const _pollDeadline = Duration(seconds: 4);

  late _SyncPhase _phase;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.recordedOffline) {
      // No radio at all — there's nothing to wait for, and waiting would
      // just make an already-known outcome look like it's still loading.
      _phase = _SyncPhase.offline;
    } else {
      _phase = _SyncPhase.confirming;
      _pollForConfirmation();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _pollForConfirmation() async {
    final deadline = DateTime.now().add(_pollDeadline);
    while (DateTime.now().isBefore(deadline)) {
      final state = await widget.checkPunchSyncState(widget.clientEventId);
      if (_disposed) return;
      if (state == PunchSyncState.confirmed) {
        setState(() => _phase = _SyncPhase.confirmed);
        return;
      }
      // A rejection surfacing inside this short window folds into the same
      // "will sync automatically" framing as still-pending — the sync-issues
      // banner (fed by _refreshSyncStatus, which already runs right after
      // this dialog closes) is where the actual rejection reason belongs,
      // not a confirmation dialog that has no room to explain it.
      if (state == PunchSyncState.rejected) {
        setState(() => _phase = _SyncPhase.stillSyncing);
        return;
      }
      await Future.delayed(_pollInterval);
      if (_disposed) return;
    }
    if (!_disposed) setState(() => _phase = _SyncPhase.stillSyncing);
  }

  Widget _statusRow() {
    final (icon, label, color, showSpinner) = switch (_phase) {
      _SyncPhase.offline => (
        Icons.cloud_off_rounded,
        'No internet — saved on this device, will sync automatically.',
        KioskColors.warning,
        false,
      ),
      _SyncPhase.stillSyncing => (
        Icons.cloud_upload_outlined,
        'Saved on this device — will sync automatically.',
        KioskColors.warning,
        false,
      ),
      _SyncPhase.confirming => (
        Icons.sync_rounded,
        'Confirming with server…',
        KioskColors.muted,
        true,
      ),
      _SyncPhase.confirmed => (
        Icons.check_circle_rounded,
        'Confirmed by server.',
        KioskColors.success,
        false,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, size: 56, color: widget.color),
          ),
          const SizedBox(height: 16),
          Text(
            widget.title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            widget.employeeName,
            style: TextStyle(
              fontSize: 17,
              color: KioskColors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (widget.overtimeSubtitle != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: widget.color.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 14,
                    color: widget.color,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.overtimeSubtitle!,
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            widget.timeString,
            style: TextStyle(fontSize: 15, color: KioskColors.muted),
          ),
          const SizedBox(height: 4),
          Text(
            'Match: ${(widget.similarity * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 13, color: KioskColors.muted),
          ),
          _statusRow(),
        ],
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              'Done',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
