import 'package:flutter/material.dart';

/// A searchable employee selector that shows as a full-screen modal bottom sheet.
/// Displays employee photos (from Supabase) with initials fallback.
class SearchableEmployeeSelector extends StatefulWidget {
  final List<Map<String, dynamic>> employees;

  const SearchableEmployeeSelector({super.key, required this.employees});

  /// Shows the selector and returns the selected employee, or null if cancelled.
  static Future<Map<String, dynamic>?> show(
    BuildContext context,
    List<Map<String, dynamic>> employees,
  ) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SearchableEmployeeSelector(employees: employees),
    );
  }

  @override
  State<SearchableEmployeeSelector> createState() =>
      _SearchableEmployeeSelectorState();
}

class _SearchableEmployeeSelectorState
    extends State<SearchableEmployeeSelector> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _filteredEmployees = [];

  @override
  void initState() {
    super.initState();
    _filteredEmployees = widget.employees;
    _searchController.addListener(_onSearch);
  }

  void _onSearch() {
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredEmployees = widget.employees;
      } else {
        _filteredEmployees = widget.employees.where((emp) {
          final firstName = (emp['first_name'] ?? '').toString().toLowerCase();
          final lastName = (emp['last_name'] ?? '').toString().toLowerCase();
          final position = (emp['position'] ?? '').toString().toLowerCase();
          final fullName = '$firstName $lastName';
          return fullName.contains(query) || position.contains(query);
        }).toList();
      }
    });
  }

  String _getInitials(Map<String, dynamic> emp) {
    final first = (emp['first_name'] ?? '').toString();
    final last = (emp['last_name'] ?? '').toString();
    String initials = '';
    if (first.isNotEmpty) initials += first[0].toUpperCase();
    if (last.isNotEmpty) initials += last[0].toUpperCase();
    return initials.isEmpty ? '?' : initials;
  }

  Color _getAvatarColor(int id) {
    final colors = [
      const Color(0xFF1E88E5), // Blue
      const Color(0xFF43A047), // Green
      const Color(0xFF8E24AA), // Purple
      const Color(0xFFE53935), // Red
      const Color(0xFFFB8C00), // Orange
      const Color(0xFF00ACC1), // Cyan
      const Color(0xFF3949AB), // Indigo
      const Color(0xFF7CB342), // Light Green
    ];
    return colors[id % colors.length];
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.people_alt_rounded,
                    color: Colors.blue.shade700,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select Employee',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      Text(
                        'Choose who you are to record attendance',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.grey[100],
                    padding: const EdgeInsets.all(8),
                  ),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by name or position...',
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 15),
                prefixIcon: Icon(Icons.search_rounded, color: Colors.grey[400]),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear_rounded,
                          color: Colors.grey[400],
                        ),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.grey[50],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: Colors.grey[200]!),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: Colors.blue.shade300,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
          ),

          // Results count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_filteredEmployees.length} employee${_filteredEmployees.length != 1 ? 's' : ''}',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),

          const Divider(height: 1),

          // Employee list
          Expanded(
            child: _filteredEmployees.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search_off_rounded,
                          size: 56,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No employees found',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Try a different search term',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _filteredEmployees.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, indent: 80, color: Colors.grey[100]),
                    itemBuilder: (context, index) {
                      final emp = _filteredEmployees[index];
                      return _buildEmployeeTile(emp);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeTile(Map<String, dynamic> emp) {
    final photoUrl = emp['photo_url'] as String?;
    final empId = emp['id'] as int;
    final firstName = emp['first_name'] ?? '';
    final lastName = emp['last_name'] ?? '';
    final position = emp['position'] ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, emp),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              // Avatar
              Hero(
                tag: 'employee_avatar_$empId',
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _getAvatarColor(empId),
                    boxShadow: [
                      BoxShadow(
                        color: _getAvatarColor(empId).withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: photoUrl != null
                      ? ClipOval(
                          child: Image.network(
                            photoUrl,
                            fit: BoxFit.cover,
                            width: 52,
                            height: 52,
                            errorBuilder: (_, __, ___) =>
                                _buildInitialsAvatar(emp),
                            loadingBuilder: (_, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                              );
                            },
                          ),
                        )
                      : _buildInitialsAvatar(emp),
                ),
              ),
              const SizedBox(width: 14),

              // Name & Position
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$firstName $lastName',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      position,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),

              // Arrow icon
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: Colors.grey[300],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInitialsAvatar(Map<String, dynamic> emp) {
    return Center(
      child: Text(
        _getInitials(emp),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
