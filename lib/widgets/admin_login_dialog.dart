import 'package:flutter/material.dart';
import '../services/supabase_service.dart';

class AdminLoginDialog extends StatelessWidget {
  final SupabaseService _supabaseService = SupabaseService();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  AdminLoginDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Admin Login"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: "Email"),
            keyboardType: TextInputType.emailAddress,
          ),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: "Password"),
            obscureText: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: () async {
            final email = _emailController.text;
            final password = _passwordController.text;

            // Show loading or just wait (simple for now)
            final success = await _supabaseService.loginAdmin(email, password);
            Navigator.pop(context, success);
          },
          child: const Text("Login"),
        ),
      ],
    );
  }
}
