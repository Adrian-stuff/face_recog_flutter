import 'package:flutter/material.dart';

class EmployeeSelector extends StatelessWidget {
  final List<Map<String, dynamic>> employees;
  final int? selectedEmployeeId;
  final ValueChanged<int?> onChanged;

  const EmployeeSelector({
    super.key,
    required this.employees,
    required this.selectedEmployeeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            isExpanded: true,
            hint: const Text("Select Employee to Register"),
            value: selectedEmployeeId,
            items: employees.map((e) {
              return DropdownMenuItem<int>(
                value: e['id'] as int,
                child: Text(
                  "${e['first_name']} ${e['last_name']} (${e['position']})",
                  style: const TextStyle(fontSize: 16),
                ),
              );
            }).toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}
