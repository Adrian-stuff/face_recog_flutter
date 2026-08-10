import 'package:flutter/material.dart';

import '../services/provisioning_service.dart';

/// One-time setup: binds this installation to a single company.
///
/// Shown when the device has never been paired, and again if the server ever
/// reports it now belongs to a different company than it was set up for.
class PairingScreen extends StatefulWidget {
  /// When true, the screen explains that the previous binding was revoked
  /// rather than presenting itself as first-time setup.
  final bool isRebind;

  const PairingScreen({super.key, this.isRebind = false});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await ProvisioningService.instance.pair(_controller.text);

    if (!mounted) return;

    if (result.success) {
      // Nothing left to do here: pair() already moved
      // ProvisioningService.state to needsNetworkSetup, and app.dart's
      // ValueListenableBuilder reacts to that by swapping this whole screen
      // out for NetworkSetupScreen on the next frame. This screen is never
      // pushed via Navigator — it's rendered directly as MaterialApp.home —
      // so there is no route here to pop. The previous `Navigator.pop()`
      // call was a no-op at best and, with asserts stripped in release
      // builds, produced a black screen instead of the intended transition.
      return;
    }

    setState(() {
      _submitting = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mismatch = ProvisioningService.instance.mismatchDetail;

    return Scaffold(
      // No back button: an unpaired device has nothing to go back to, and a
      // mismatched one must not be dismissed into a working-looking state.
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    widget.isRebind ? Icons.gpp_maybe : Icons.tablet_android,
                    size: 64,
                    color: widget.isRebind
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.isRebind ? 'This device needs re-pairing' : 'Set up this device',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.isRebind
                        ? 'The cached employee data for the previous company has been '
                              'removed from this device. Enter a new pairing code to continue.'
                        : 'In the web dashboard, go to Settings → Kiosk devices and '
                              'generate a pairing code. Codes expire after 15 minutes.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (widget.isRebind && mismatch != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        mismatch,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  TextField(
                    controller: _controller,
                    enabled: !_submitting,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      letterSpacing: 4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      hintText: 'XXXX-XXXX',
                      border: const OutlineInputBorder(),
                      errorText: _error,
                      // Codes are read aloud or copied off a screen, so the
                      // server normalises case and punctuation — the user
                      // doesn't have to reproduce the hyphen exactly.
                      helperText: 'Case and dashes don\'t matter',
                      helperMaxLines: 2,
                      errorMaxLines: 3,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Pair device'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
