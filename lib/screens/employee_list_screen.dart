import 'package:flutter/material.dart';
import '../services/local_database_service.dart';
import 'add_face_screen.dart';

class EmployeeListScreen extends StatefulWidget {
  const EmployeeListScreen({super.key});

  @override
  State<EmployeeListScreen> createState() => _EmployeeListScreenState();
}

class _EmployeeListScreenState extends State<EmployeeListScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
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
    final employees = await _db.getAllEmployees();
    if (mounted) {
      setState(() {
        _employees = employees;
        _filteredEmployees = employees;
        _isLoading = false;
      });
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
                : ListView.builder(
                    itemCount: _filteredEmployees.length,
                    itemBuilder: (context, index) {
                      final employee = _filteredEmployees[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(employee['first_name'][0]),
                        ),
                        title: Text(
                          "${employee['first_name']} ${employee['last_name']}",
                        ),
                        subtitle: Text(employee['position'] ?? 'No Position'),
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
