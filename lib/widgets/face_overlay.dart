import 'package:flutter/material.dart';

class FaceOverlay extends StatelessWidget {
  final bool isLive;
  final String statusMessage;
  final bool canRegister;
  final VoidCallback?
  onRegister; // Keeping for backward compatibility or admin mode
  final VoidCallback? onTimeIn;
  final VoidCallback? onTimeOut;

  const FaceOverlay({
    super.key,
    required this.isLive,
    required this.statusMessage,
    required this.canRegister,
    this.onRegister,
    this.onTimeIn,
    this.onTimeOut,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Bounding Box / Face Frame
        Center(
          child: Container(
            width: 300,
            height: 300,
            decoration: BoxDecoration(
              border: Border.all(
                color: isLive ? Colors.green : Colors.red,
                width: 4,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),

        // Status Message
        Positioned(
          bottom: 120, // Moved up to make room for buttons
          left: 20,
          right: 20,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isLive ? Colors.greenAccent : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),

        // Action Buttons
        Positioned(
          bottom: 40,
          left: 20,
          right: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (onTimeIn != null)
                _buildActionButton(
                  context,
                  label: "TIME IN",
                  color: Colors.green,
                  onPressed: canRegister ? onTimeIn : null,
                ),

              if (onTimeOut != null)
                _buildActionButton(
                  context,
                  label: "TIME OUT",
                  color: Colors.orange,
                  onPressed: canRegister ? onTimeOut : null,
                ),

              // Keep Register button if explicitly provided (e.g. for initial enrollment)
              if (onRegister != null && onTimeIn == null && onTimeOut == null)
                _buildActionButton(
                  context,
                  label: "REGISTER FACE",
                  color: Colors.blue,
                  onPressed: canRegister ? onRegister : null,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required String label,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
