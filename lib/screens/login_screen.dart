import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:beszel_pro/services/pin_service.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:beszel_pro/screens/appearance_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final pb = PocketBaseService().pb;

      await pb
          .collection('users')
          .authWithPassword(
            _emailController.text.trim(),
            _passwordController.text,
          );

      if (mounted) {
        // Check if PIN is set
        final isPinSet = await PinService().isPinSet();

        if (!mounted) return;

        if (!isPinSet) {
          // New flow: Login -> Appearance -> PinDecision
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AppearanceScreen()));
        } else {
          // Even if PIN is set, verify/show appearance?
          // Assuming first login on device means setup needed?
          // Or just skip for existing?
          // User wants "initialization".
          // If checking isPinSet here, it implies it's checking the ACCOUNT's pin status or DEVICE's?
          // PinService uses SharedPreferences, so it is DEVICE specific.
          // If local pin is set, user has used app before on this device.
          // So skipping appearance is fine.
          // BUT if user WANTS to see it?
          // Let's force it for newly logged in users (since they land on this screen).
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AppearanceScreen()));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Login failed. Please check your credentials.';
          if (e is ClientException) {
            _error = e.response['message']?.toString() ?? e.toString();
          } else {
            _error = e.toString();
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('login'.tr()),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.secondaryContainer.withValues(alpha: 0.34),
              colorScheme.surface,
              colorScheme.primaryContainer.withValues(alpha: 0.34),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Icon(
                              Icons.security,
                              color: colorScheme.onPrimary,
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Beszel Pro',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'login'.tr(),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: 'email_username'.tr(),
                            prefixIcon: const Icon(Icons.person),
                          ),
                          autocorrect: false,
                          textCapitalization: TextCapitalization.none,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _passwordController,
                          decoration: InputDecoration(
                            labelText: 'password'.tr(),
                            prefixIcon: const Icon(Icons.lock),
                          ),
                          obscureText: true,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _LoginErrorBanner(message: _error!),
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _isLoading ? null : _login,
                          icon: _isLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text('login'.tr()),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginErrorBanner extends StatelessWidget {
  const _LoginErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
