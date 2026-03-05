import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/local_database_service.dart';
import '../services/supabase_service.dart';
import '../config/app_config.dart';
import 'add_face_screen.dart';

class EmployeeListScreen extends StatefulWidget {
  const EmployeeListScreen({super.key});

  @override
  State<EmployeeListScreen> createState() => _EmployeeListScreenState();
}

class _EmployeeListScreenState extends State<EmployeeListScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
  final SupabaseService _supabaseService = SupabaseService();
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_filterEmployees);
  }

  Future<void> _loadEmployees() async {
    if (!mounted) return;

    try {
      // Sync employees from backend (with caching)
      await _supabaseService.syncEmployees();

      // Load from local database
      final employees = await _db.getAllEmployees();

      if (mounted) {
        setState(() {
          _employees = employees;
          _filteredEmployees = employees;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading employees: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _filterEmployees() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredEmployees = _employees.where((e) {
        final name = "${e['first_name']} ${e['last_name']}".toLowerCase();
        return name.contains(query);
      }).toList();
    });
  }

  /// Builds avatar widget with proper caching and error handling
  Widget _buildEmployeeAvatar(Map<String, dynamic> employee) {
    final employeeId = employee['id'] as int?;
    final localImagePath = employee['local_image_path'] as String?;
    final imageUrl = employee['image_url'] as String?;

    if (employeeId == null) {
      return _buildInitialAvatar(employee);
    }

    // Try local cached image first
    if (localImagePath != null && localImagePath.isNotEmpty) {
      final file = File(localImagePath);
      if (file.existsSync()) {
        return ClipOval(
          child: Image.file(
            file,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('Error loading local image for $employeeId: $error');
              return _buildInitialAvatar(employee);
            },
          ),
        );
      }
    }

    // Fall back to cached network image from avatar endpoint or image_url
    final avatarUrl = AppConfig.getEmployeeAvatarUrl(employeeId);

    return CachedNetworkImage(
      imageUrl: avatarUrl,
      fit: BoxFit.cover,
      width: 40,
      height: 40,
      fadeInDuration: const Duration(milliseconds: 300),
      placeholder: (context, url) {
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            shape: BoxShape.circle,
          ),
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
      errorWidget: (context, url, error) {
        debugPrint('Error loading avatar for employee $employeeId: $error');
        // Try fallback to image_url if avatar endpoint fails
        if (imageUrl != null && imageUrl.isNotEmpty && url != imageUrl) {
          return CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            width: 40,
            height: 40,
            errorWidget: (context, url, error) {
              return _buildInitialAvatar(employee);
            },
          );
        }
        return _buildInitialAvatar(employee);
      },
    );
  }

  /// Builds fallback avatar with employee initials
  Widget _buildInitialAvatar(Map<String, dynamic> employee) {
    final firstName = (employee['first_name'] as String?) ?? '';
    final lastName = (employee['last_name'] as String?) ?? '';
    final initials =
        (firstName.isNotEmpty ? firstName[0] : '') +
        (lastName.isNotEmpty ? lastName[0] : '');

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color:
            Colors.primaries[((employee['id'] as int? ?? 0) %
                Colors.primaries.length)],
      ),
      child: Center(
        child: Text(
          initials.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Employees")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: "Search Employee",
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredEmployees.isEmpty
                ? Center(
                    child: Text(
                      _employees.isEmpty
                          ? 'No employees found'
                          : 'No matches for "${_searchController.text}"',
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredEmployees.length,
                    itemBuilder: (context, index) {
                      final employee = _filteredEmployees[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.transparent,
                          child: _buildEmployeeAvatar(employee),
                        ),
                        title: Text(
                          "${employee['first_name'] ?? ''} ${employee['last_name'] ?? ''}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          employee['position'] ?? 'No Position',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AddFaceScreen(employee: employee),
                            ),
                          );
                          if (result == true) {
                            _loadEmployees(); // Refresh list only if changed
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
