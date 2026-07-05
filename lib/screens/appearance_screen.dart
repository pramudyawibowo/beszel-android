import 'package:beszel_pro/providers/app_provider.dart';
import 'package:beszel_pro/screens/dashboard_screen.dart';
import 'package:beszel_pro/screens/pin_decision_screen.dart';
import 'package:beszel_pro/services/pin_service.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  Future<void> _next(BuildContext context) async {
    final isPinSet = await PinService().isPinSet();
    if (!context.mounted) return;

    if (!isPinSet) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const PinDecisionScreen()),
        (route) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('appearance'.tr())),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'choose_view_mode'.tr(),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Consumer<AppProvider>(
                builder: (context, provider, _) {
                  return ListView(
                    children: [
                      _buildSectionCard(
                        context,
                        title: 'choose_view_mode'.tr(),
                        child: Column(
                          children: [
                            _buildOption(
                              context,
                              title: 'view_simple'.tr(),
                              icon: Icons.view_agenda_outlined,
                              isSelected: !provider.isDetailed,
                              onTap: () => provider.setDetailedMode(false),
                            ),
                            const SizedBox(height: 16),
                            _buildOption(
                              context,
                              title: 'view_detailed'.tr(),
                              icon: Icons.view_list,
                              isSelected: provider.isDetailed,
                              onTap: () => provider.setDetailedMode(true),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildSectionCard(
                        context,
                        title: 'refresh_interval'.tr(),
                        child: DropdownButtonFormField<int>(
                          value: provider.refreshIntervalSeconds,
                          decoration: InputDecoration(
                            labelText: 'refresh_every'.tr(),
                          ),
                          isExpanded: true,
                          items: [1, 2, 5, 10, 30]
                              .map(
                                (seconds) => DropdownMenuItem<int>(
                                  value: seconds,
                                  child: Text(
                                    '$seconds ${tr('seconds')}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              provider.setRefreshIntervalSeconds(value);
                            }
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            ElevatedButton(
              onPressed: () => _next(context),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text('continue'.tr()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildOption(
    BuildContext context, {
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primaryContainer : null,
          border: Border.all(
            color: isSelected ? colorScheme.primary : Colors.grey,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected ? colorScheme.primary : Colors.grey,
            ),
            const SizedBox(width: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? colorScheme.onPrimaryContainer : null,
              ),
            ),
            const Spacer(),
            if (isSelected)
              Icon(Icons.check_circle, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }
}
