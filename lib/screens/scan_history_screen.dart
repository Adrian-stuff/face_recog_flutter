import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/local_database_service.dart';
import '../services/supabase_service.dart';

/// On-device record of every scan this kiosk performed and what became of it.
///
/// The column that matters is the rightmost one: whether the server has
/// confirmed it actually holds an attendance record for that scan. A scan the
/// device believes it sent, that the server does not have, is the case people
/// argue about — and it is now visible here instead of being invisible.
class ScanHistoryScreen extends StatefulWidget {
  const ScanHistoryScreen({super.key});

  @override
  State<ScanHistoryScreen> createState() => _ScanHistoryScreenState();
}

class _ScanHistoryScreenState extends State<ScanHistoryScreen> {
  final _localDb = LocalDatabaseService();
  final _supabaseService = SupabaseService();

  List<Map<String, dynamic>> _events = const [];
  bool _loading = true;
  bool _unconfirmedOnly = false;
  bool _reconciling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final events = await _localDb.getScanEvents(
      unconfirmedOnly: _unconfirmedOnly,
    );
    if (!mounted) return;
    setState(() {
      _events = events;
      _loading = false;
    });
  }

  Future<void> _reconcileNow() async {
    setState(() => _reconciling = true);
    await _supabaseService.reconcileWithServer();
    if (!mounted) return;
    setState(() => _reconciling = false);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Checked against the server')),
    );
  }

  Future<void> _showEvidence(Map<String, dynamic> event) async {
    final clientEventId = event['client_event_id'] as String;
    final thumbnail = await _localDb.getScanThumbnail(clientEventId);
    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(event['employee_name'] as String? ?? 'Unmatched scan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumbnail != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(base64Decode(thumbnail), height: 220),
              )
            else
              const Text('No image was captured for this scan.'),
            const SizedBox(height: 16),
            _DetailRow('Scanned', _formatTime(event['scanned_at'] as String)),
            _DetailRow('Outcome', _outcomeLabel(event['outcome'] as String)),
            if (event['attendance_type'] != null)
              _DetailRow('Type', event['attendance_type'] as String),
            if (event['match_confidence'] != null)
              _DetailRow(
                'Confidence',
                '${((event['match_confidence'] as num) * 100).toStringAsFixed(1)}%',
              ),
            _DetailRow(
              'Server confirmed',
              event['server_confirmed'] == 1 ? 'Yes' : 'No',
            ),
            if (event['rejection_reason'] != null)
              _DetailRow('Reason', event['rejection_reason'] as String),
            // The id an admin can search for in the dashboard to find the
            // matching server-side record (or confirm there isn't one).
            _DetailRow('Event ID', clientEventId),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _formatTime(String iso) {
    try {
      return DateFormat('MMM d, h:mm:ss a').format(DateTime.parse(iso));
    } catch (_) {
      return iso;
    }
  }

  static String _outcomeLabel(String outcome) {
    switch (outcome) {
      case 'recorded':
        return 'Recorded';
      case 'pending_sync':
        return 'Waiting to sync';
      case 'server_rejected':
        return 'Rejected by server';
      case 'no_match':
        return 'No match';
      case 'liveness_failed':
        return 'Liveness failed';
      case 'device_rejected':
        return 'Declined (already recorded)';
      default:
        return outcome;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan history'),
        actions: [
          IconButton(
            tooltip: 'Check against server',
            icon: _reconciling
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            onPressed: _reconciling ? null : _reconcileNow,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_events.length} scan${_events.length == 1 ? '' : 's'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                FilterChip(
                  label: const Text('Unconfirmed only'),
                  selected: _unconfirmedOnly,
                  onSelected: (v) {
                    setState(() => _unconfirmedOnly = v);
                    _load();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _events.isEmpty
                ? Center(
                    child: Text(
                      _unconfirmedOnly
                          ? 'Every scan has been confirmed by the server.'
                          : 'No scans recorded yet.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      itemCount: _events.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final event = _events[index];
                        return _ScanTile(
                          event: event,
                          onTap: () => _showEvidence(event),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  final Map<String, dynamic> event;
  final VoidCallback onTap;

  const _ScanTile({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = event['outcome'] as String;
    final confirmed = event['server_confirmed'] == 1;
    final uploaded = event['is_uploaded'] == 1;

    // The state worth drawing attention to: the device believes this scan
    // succeeded, but the server has never confirmed holding it.
    final isDisputed = outcome == 'recorded' && !confirmed;

    final (icon, color) = switch (outcome) {
      'recorded' when confirmed => (Icons.check_circle, Colors.green),
      'recorded' => (Icons.help, Colors.orange),
      'pending_sync' => (Icons.schedule, Colors.blueGrey),
      'server_rejected' => (Icons.cancel, theme.colorScheme.error),
      'no_match' => (Icons.person_off, Colors.deepOrange),
      'liveness_failed' => (Icons.visibility_off, Colors.deepOrange),
      _ => (Icons.help_outline, Colors.grey),
    };

    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color),
      title: Text(
        event['employee_name'] as String? ?? 'Unmatched scan',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${_ScanHistoryScreenState._formatTime(event['scanned_at'] as String)}'
        ' · ${_ScanHistoryScreenState._outcomeLabel(outcome)}'
        '${event['has_thumbnail'] == 1 ? ' · photo' : ''}',
      ),
      trailing: isDisputed
          ? Tooltip(
              message: 'Recorded on this device, but the server has not '
                  'confirmed it. Tap to see the evidence.',
              child: Chip(
                label: const Text('Unconfirmed'),
                backgroundColor: Colors.orange.shade100,
                labelStyle: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                visualDensity: VisualDensity.compact,
              ),
            )
          : (uploaded ? null : const Icon(Icons.cloud_upload_outlined, size: 18)),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
            ),
          ),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}
