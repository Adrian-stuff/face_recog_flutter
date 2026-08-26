import 'package:flutter/material.dart';

/// A stable colour for an employee's initials avatar.
///
/// Keyed off the employee id rather than their name so the colour survives a
/// rename, and stays the same everywhere the person appears — recognising a
/// familiar swatch is most of what makes a list of initials scannable.
Color employeeAvatarColor(int id) {
  const colors = [
    Color(0xFF1E88E5),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFF00ACC1),
    Color(0xFF3949AB),
    Color(0xFF7CB342),
  ];
  return colors[id % colors.length];
}

/// First initial of each name, e.g. "Ana Cruz" -> "AC". Falls back to "?"
/// rather than an empty circle when the roster row has no name at all.
String employeeInitials(Map<String, dynamic> employee) {
  final first = (employee['first_name'] ?? '').toString();
  final last = (employee['last_name'] ?? '').toString();
  var initials = '';
  if (first.isNotEmpty) initials += first[0].toUpperCase();
  if (last.isNotEmpty) initials += last[0].toUpperCase();
  return initials.isEmpty ? '?' : initials;
}

/// Full name for display, or "Unknown employee" when the row carries none.
String employeeDisplayName(Map<String, dynamic> employee) {
  final first = (employee['first_name'] ?? '').toString();
  final last = (employee['last_name'] ?? '').toString();
  final full = '$first $last'.trim();
  return full.isEmpty ? 'Unknown employee' : full;
}
