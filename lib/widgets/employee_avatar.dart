import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../utils/employee_display.dart';

/// An employee's face, falling back to their initials.
///
/// Tries the copy already on disk before the network. A kiosk that has synced
/// once has every photo cached locally, so the offline case — the one where
/// someone most needs to confirm the machine picked the right person — should
/// not depend on a request that cannot succeed.
class EmployeeAvatar extends StatelessWidget {
  const EmployeeAvatar({
    super.key,
    required this.employee,
    this.size = 52,
    this.fontSize,
  });

  final Map<String, dynamic> employee;
  final double size;

  /// Defaults to a proportion of [size], which keeps two-letter initials
  /// inside the circle at any size this is used at.
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final id = employee['id'];
    final background = id is int
        ? employeeAvatarColor(id)
        : const Color(0xFF63626A);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: background),
      clipBehavior: Clip.antiAlias,
      child: id is int ? _image(id) : _initials(),
    );
  }

  Widget _image(int id) {
    final localPath = employee['local_image_path'] as String?;
    if (localPath != null && localPath.isNotEmpty) {
      final file = File(localPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initials(),
        );
      }
    }

    final photoUrl = employee['photo_url'] as String?;
    return CachedNetworkImage(
      imageUrl: AppConfig.getEmployeeAvatarUrl(id),
      width: size,
      height: size,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 200),
      // Initials rather than a spinner: the avatar endpoint is one hop away
      // on the office LAN, and a circle that flickers spinner-then-face on
      // every rebuild reads as the kiosk struggling.
      placeholder: (_, _) => _initials(),
      errorWidget: (_, url, _) {
        // The avatar endpoint is the sized/cropped one; photo_url is the
        // original upload, worth a try before giving up on a face entirely.
        if (photoUrl != null && photoUrl.isNotEmpty && url != photoUrl) {
          return CachedNetworkImage(
            imageUrl: photoUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: (_, _) => _initials(),
            errorWidget: (_, _, _) => _initials(),
          );
        }
        return _initials();
      },
    );
  }

  Widget _initials() {
    return Center(
      child: Text(
        employeeInitials(employee),
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize ?? size * 0.38,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
