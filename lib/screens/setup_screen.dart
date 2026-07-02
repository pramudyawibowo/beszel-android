import 'package:beszel_pro/screens/login_screen.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_localization/easy_localization.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    String url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _isLoading = false;
        _error = tr('enter_valid_url');
      });
      return;
    }

    // Basic normalization
    if (!url.startsWith('http')) {
      url = 'https://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    try {
      // Connect to PocketBase
      await PocketBaseService().connect(url);

      // Verify connection by checking health
      await PocketBaseService().pb.health.check();

      // Save URL for future app launches
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pb_url', url);

      if (mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
      }
    } catch (e) {
      setState(() {
        // Show specific "URL incorrect" message if it looks like a connection error
        _error = tr('url_incorrect');
        debugPrint('Connection error: $e');
      });
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
        title: Text('setup_title'.tr()),
        actions: [
          PopupMenuButton<Locale>(
            icon: const Icon(Icons.language),
            tooltip: 'Language',
            onSelected: (Locale locale) {
              context.setLocale(locale);
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<Locale>>[
              const PopupMenuItem<Locale>(
                value: Locale('en'),
                child: Text('🇺🇸 English'),
              ),
              const PopupMenuItem<Locale>(
                value: Locale('ru'),
                child: Text('🇷🇺 Русский'),
              ),
              const PopupMenuItem<Locale>(
                value: Locale('zh', 'CN'),
                child: Text('🇨🇳 简体中文'),
              ),
            ],
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.primaryContainer.withValues(alpha: 0.42),
              colorScheme.surface,
              colorScheme.secondaryContainer.withValues(alpha: 0.28),
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
                              Icons.hub,
                              color: colorScheme.onPrimary,
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'enter_url'.tr(),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'server_url'.tr(),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            labelText: 'server_url'.tr(),
                            hintText: 'https://monitor.mydomain.com',
                            prefixIcon: const Icon(Icons.link),
                          ),
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          textCapitalization: TextCapitalization.none,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBanner(message: _error!),
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _isLoading ? null : _connect,
                          icon: _isLoading
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_forward),
                          label: const Text('Connect'),
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

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
