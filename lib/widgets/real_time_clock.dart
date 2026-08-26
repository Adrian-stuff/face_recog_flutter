import 'dart:async';
import 'package:flutter/material.dart';

import '../config/kiosk_config.generated.dart';

/// The kiosk's clock, sized to be read from across a room.
///
/// Time and date are separate lines rather than one run of text: at this
/// size a single "Mon, 25 Oct 2023 | 10:30:05 AM" string either overflows a
/// phone-width kiosk or has to be shrunk back down to the point that being
/// large stops meaning anything. Splitting them lets the time carry the
/// weight and the date sit quietly underneath.
class RealTimeClock extends StatefulWidget {
  const RealTimeClock({super.key});

  @override
  State<RealTimeClock> createState() => _RealTimeClockState();
}

class _RealTimeClockState extends State<RealTimeClock> {
  late Timer _timer;
  late DateTime _dateTime;

  @override
  void initState() {
    super.initState();
    _dateTime = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _dateTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  // Formatted by hand rather than through intl, as before — this widget is
  // on the first frame the kiosk paints and shouldn't wait on locale data.
  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _formatDate(DateTime dt) =>
      '${_weekdays[dt.weekday - 1]}, ${_months[dt.month - 1]} ${dt.day}, ${dt.year}';

  @override
  Widget build(BuildContext context) {
    var hour = _dateTime.hour;
    final minute = _dateTime.minute.toString().padLeft(2, '0');
    final second = _dateTime.second.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    if (hour > 12) hour -= 12;
    if (hour == 0) hour = 12;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Baseline-aligned so the seconds and AM/PM sit on the same line as
        // the hours rather than floating against the digits' full height.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$hour:$minute',
                style: const TextStyle(
                  fontSize: 60,
                  height: 1.05,
                  fontWeight: FontWeight.w600,
                  color: KioskColors.baseContent,
                  letterSpacing: -1.5,
                  // Constant-width digits, so the layout doesn't twitch on
                  // every tick.
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                second,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  color: KioskColors.muted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                period,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: KioskColors.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            _formatDate(_dateTime),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: KioskColors.muted,
            ),
          ),
        ),
      ],
    );
  }
}
