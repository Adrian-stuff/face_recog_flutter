import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/local_database_service.dart';

/// Who has clocked in/out on this device today, for employees to check —
/// "did I actually get recorded?" or "has so-and-so come in yet?" — without
/// needing an admin to look it up for them.
///
/// Deliberately shallow compared to [ScanHistoryScreen]: no thumbnails, no
/// rejection reasons, no unmatched/failed attempts, no sync/event-id
/// internals. Just name, punch type, and time — the same information an
/// employee could get by asking whoever's at the front desk, just faster.
class TodayAttendanceScreen extends StatefulWidget {
  const TodayAttendanceScreen({super.key});

  @override
  State<TodayAttendanceScreen> createState() => _TodayAttendanceScreenState();
}

class _TodayAttendanceScreenState extends State<TodayAttendanceScreen> {
  final _localDb = LocalDatabaseService();

  List<Map<String, dynamic>> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await _localDb.getTodayAttendance();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  static String _employeeName(Map<String, dynamic> entry) {
    final first = entry['first_name'] as String? ?? '';
    final last = entry['last_name'] as String? ?? '';
    final full = '$first $last'.trim();
    return full.isEmpty ? 'Unknown employee' : full;
  }

  static String _formatTime(String iso) {
    try {
      return DateFormat('h:mm a').format(DateTime.parse(iso));
    } catch (_) {
      return iso;
    }
  }

  static (String, IconData, Color) _typeDisplay(String type) {
    switch (type) {
      case 'time-in':
        return ('Time In', Icons.login, Colors.green);
      case 'time-out':
        return ('Time Out', Icons.logout, Colors.blueGrey);
      case 'overtime-in':
        return ('Overtime In', Icons.login, Colors.teal);
      case 'overtime-out':
        return ('Overtime Out', Icons.logout, Colors.deepPurple);
      default:
        return (type, Icons.check_circle_outline, Colors.grey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateFormat('EEEE, MMMM d').format(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text("Today's Attendance"),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(today, style: theme.textTheme.titleMedium),
                  ),
                  Text(
                    '${_entries.length} punch${_entries.length == 1 ? '' : 'es'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _entries.isEmpty
                  ? Center(
                      child: Text(
                        'No one has scanned in yet today.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          final (label, icon, color) = _typeDisplay(
                            entry['type'] as String,
                          );
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.15),
                              child: Icon(icon, color: color),
                            ),
                            title: Text(
                              _employeeName(entry),
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(label),
                            trailing: Text(
                              _formatTime(entry['timestamp'] as String),
                              style: theme.textTheme.bodyMedium,
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
