import 'package:beszel_pro/models/system.dart';
import 'dart:async';
import 'package:beszel_pro/screens/system_detail_screen.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:flutter/material.dart';
import 'package:beszel_pro/screens/setup_screen.dart';

import 'package:beszel_pro/providers/app_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:beszel_pro/services/notification_service.dart';
import 'package:beszel_pro/services/alert_manager.dart';
import 'package:beszel_pro/screens/alerts_screen.dart';
import 'package:beszel_pro/screens/appearance_screen.dart';
import 'package:beszel_pro/screens/user_info_screen.dart';
import 'package:beszel_pro/services/pin_service.dart';

enum SortOption { name, cpu, ram, disk }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<System> _systems = [];
  Map<String, List<int>> _cumulativeTraffic = {}; // systemId -> [sent, recv]
  Map<String, bool> _systemsWithGpu = {}; // systemId -> has GPU data
  bool _isLoading = true;
  bool _isOffline = false;
  String? _error;
  SortOption _currentSort = SortOption.name; // Default sort
  Timer? _pollingTimer;
  int _pollIntervalSeconds = 5;
  bool _pollInProgress = false;
  bool _initialLoadStarted = false;

  void _sortSystems() {
    switch (_currentSort) {
      case SortOption.name:
        _systems.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortOption.cpu:
        // Descending for metrics usually makes more sense
        _systems.sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));
        break;
      case SortOption.ram:
        _systems.sort((a, b) => b.memoryPercent.compareTo(a.memoryPercent));
        break;
      case SortOption.disk:
        _systems.sort((a, b) => b.diskPercent.compareTo(a.diskPercent));
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    debugPrint('Dashboard: initState');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final intervalSeconds = context.watch<AppProvider>().refreshIntervalSeconds;
    if (_pollIntervalSeconds != intervalSeconds) {
      _pollIntervalSeconds = intervalSeconds;
      _restartPollingTimer();
    }

    if (!_initialLoadStarted) {
      _initialLoadStarted = true;
      // Defer heavy services until after the first frame rendered
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('Dashboard: PostFrameCallback - Starting Services');
        NotificationService().initialize();
        AlertManager().loadAlerts();
        _fetchSystems();
        _subscribeToRealtime();
        _restartPollingTimer();
      });
    }
  }

  void _restartPollingTimer() {
    _pollingTimer?.cancel();
    if (_pollIntervalSeconds <= 0) {
      return;
    }
    _pollingTimer = Timer.periodic(
      Duration(seconds: _pollIntervalSeconds),
      (timer) {
        _pollSystems();
      },
    );
  }

  Future<void> _pollSystems() async {
    if (_pollInProgress) return;
    _pollInProgress = true;
    // Silent fetch
    try {
      final pb = PocketBaseService().pb;
      final records = await pb
          .collection('systems')
          .getFullList(sort: '-updated');
      if (!mounted) return;

      final newSystems = records.map((r) => System.fromRecord(r)).toList();
      setState(() {
        for (var newSys in newSystems) {
          final index = _systems.indexWhere((s) => s.id == newSys.id);
          if (index != -1) {
            final oldSys = _systems[index];
            _checkAlerts(oldSys, newSys);
            _systems[index] = newSys;
          } else {
            _systems.add(newSys);
          }
        }
        _sortSystems();
      });
    } catch (_) {
    } finally {
      _pollInProgress = false;
    }
  }

  void _checkAlerts(System oldSystem, System newSystem) {
    if (Provider.of<AlertManager>(context, listen: false).alerts.isNotEmpty) {
      return;
    }
    // 1. Check for DOWN status
    if (oldSystem.status == 'up' && newSystem.status == 'down') {
      _triggerAlert(
        newSystem,
        tr('alert_system_down_title'),
        tr('alert_system_down_body', args: [newSystem.name]),
        'error',
      );
    }
    // 2. Check for High CPU (80%)
    if (newSystem.cpuPercent > 80 && oldSystem.cpuPercent <= 80) {
      _triggerAlert(
        newSystem,
        tr('alert_high_cpu_title'),
        tr(
          'alert_high_cpu_body',
          args: [newSystem.name, newSystem.cpuPercent.toStringAsFixed(1)],
        ),
        'warning',
      );
    }
    // 3. Check for High RAM (80%)
    if (newSystem.memoryPercent > 80 && oldSystem.memoryPercent <= 80) {
      _triggerAlert(
        newSystem,
        tr('alert_high_ram_title'),
        tr(
          'alert_high_ram_body',
          args: [newSystem.name, newSystem.memoryPercent.toStringAsFixed(1)],
        ),
        'warning',
      );
    }
    // 4. Check for High Disk (80%)
    if (newSystem.diskPercent > 80 && oldSystem.diskPercent <= 80) {
      _triggerAlert(
        newSystem,
        tr('alert_high_disk_title'),
        tr(
          'alert_high_disk_body',
          args: [newSystem.name, newSystem.diskPercent.toStringAsFixed(1)],
        ),
        'warning',
      );
    }
  }

  void _checkInitialAlerts() {
    if (Provider.of<AlertManager>(context, listen: false).alerts.isNotEmpty) {
      return;
    }
    for (final system in _systems) {
      // 1. Check for DOWN status
      if (system.status == 'down') {
        _triggerAlert(
          system,
          tr('alert_system_down_title'),
          tr('alert_system_down_body', args: [system.name]),
          'error',
        );
      }
      // 2. Check for High CPU (80%)
      if (system.cpuPercent > 80) {
        _triggerAlert(
          system,
          tr('alert_high_cpu_title'),
          tr(
            'alert_high_cpu_body',
            args: [system.name, system.cpuPercent.toStringAsFixed(1)],
          ),
          'warning',
        );
      }
      // 3. Check for High RAM (80%)
      if (system.memoryPercent > 80) {
        _triggerAlert(
          system,
          tr('alert_high_ram_title'),
          tr(
            'alert_high_ram_body',
            args: [system.name, system.memoryPercent.toStringAsFixed(1)],
          ),
          'warning',
        );
      }
      // 4. Check for High Disk (80%)
      if (system.diskPercent > 80) {
        _triggerAlert(
          system,
          tr('alert_high_disk_title'),
          tr(
            'alert_high_disk_body',
            args: [system.name, system.diskPercent.toStringAsFixed(1)],
          ),
          'warning',
        );
      }
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _unsubscribeFromRealtime();
    super.dispose();
  }

  Future<void> _fetchSystems() async {
    if (mounted) {
      setState(() {
        _isOffline = false;
        _error = null;
      });
    }

    try {
      final pb = PocketBaseService().pb;
      final records = await pb
          .collection('systems')
          .getFullList(sort: '-updated');

      if (records.isNotEmpty) {
        debugPrint('SYSTEM RECORD RAW DATA: ${records.first.data}');
      }

      if (mounted) {
        setState(() {
          _systems = records.map((r) => System.fromRecord(r)).toList();
          _sortSystems();
          _checkInitialAlerts();
          _isLoading = false;
        });

        // Fetch cumulative traffic for each system (in background)
        _fetchCumulativeTraffic();
      }
    } catch (e) {
      if (mounted) {
        final errString = e.toString();
        debugPrint('Fetch error: $errString');
        setState(() {
          if (errString.contains('ClientException') ||
              errString.contains('SocketException') ||
              errString.contains('Failed host lookup')) {
            _isOffline = true;
          } else {
            _error = 'Failed to load systems: $e';
          }
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchCumulativeTraffic() async {
    // Fetch cumulative traffic for each system from system_stats collection
    // Cumulative data is in stats['ni'] (NetworkInterfaces) as:
    // { "eth0": [upDelta, downDelta, totalBytesSent, totalBytesRecv], ... }
    try {
      final pb = PocketBaseService().pb;
      final Map<String, List<int>> trafficMap = {};
      final Map<String, bool> gpuMap = {};

      for (final system in _systems) {
        try {
          // Get the latest stats record for this system
          final statsRecords = await pb
              .collection('system_stats')
              .getList(
                page: 1,
                perPage: 1,
                filter: 'system = "${system.id}"',
                sort: '-created',
              );

          if (statsRecords.items.isNotEmpty) {
            final stats = statsRecords.items.first.data['stats'];
            if (stats != null && stats['ni'] != null) {
              // ni = NetworkInterfaces map
              // Each interface: [upDelta, downDelta, totalBytesSent, totalBytesRecv]
              final ni = stats['ni'];
              if (ni is Map) {
                int totalSent = 0;
                int totalRecv = 0;
                ni.forEach((key, value) {
                  if (value is List && value.length >= 4) {
                    totalSent += ((value[2] is num)
                        ? (value[2] as num).toInt()
                        : 0);
                    totalRecv += ((value[3] is num)
                        ? (value[3] as num).toInt()
                        : 0);
                  }
                });
                trafficMap[system.id] = [totalSent, totalRecv];
              }
            }

            // Detect whether this system has GPU data at all.
            // GPU utilization can legitimately be 0, so presence is based on
            // whether the stats payload includes a non-empty GPU map.
            if (stats != null && stats['g'] is Map) {
              final gpus = stats['g'] as Map;
              gpuMap[system.id] = gpus.isNotEmpty;
            }
          }
        } catch (e) {
          debugPrint('Failed to fetch stats for ${system.name}: $e');
        }
      }

      if (mounted) {
        setState(() {
          _cumulativeTraffic = trafficMap;
          _systemsWithGpu = gpuMap;
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch cumulative traffic: $e');
    }
  }

  Widget _buildOfflineWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.signal_wifi_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            tr('no_internet'),
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _isLoading = true;
                _isOffline = false;
                _error = null;
              });
              _fetchSystems();
            },
            icon: const Icon(Icons.refresh),
            label: Text(
              tr('refresh'),
            ), // Fallback if 'refresh' key missing, though ideally add to en.json too or use Icon button
          ),
        ],
      ),
    );
  }

  // Summary card showing aggregated statistics
  Widget _buildSummaryCard(BuildContext context) {
    // Calculate server counts
    final totalServers = _systems.length;
    final onlineServers = _systems.where((s) => s.status == 'up').length;
    final offlineServers = totalServers - onlineServers;

    // Calculate total real-time bandwidth (sum of all info['bb'])
    double totalBandwidth = 0;
    for (final sys in _systems) {
      if (sys.info['bb'] != null && sys.info['bb'] is num) {
        totalBandwidth += (sys.info['bb'] as num).toDouble();
      }
    }

    // Calculate total cumulative traffic (sum of all cumulativeTraffic)
    int totalSent = 0;
    int totalRecv = 0;
    for (final sys in _systems) {
      final traffic = _cumulativeTraffic[sys.id];
      if (traffic != null && traffic.length >= 2) {
        totalSent += traffic[0];
        totalRecv += traffic[1];
      }
    }

    // Format bytes helper (inline version for this widget)
    String formatBytes(double bytes) {
      if (bytes <= 0) return '0 B';
      const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
      var i = 0;
      while (bytes >= 1024 && i < suffixes.length - 1) {
        bytes /= 1024;
        i++;
      }
      return '${bytes.toStringAsFixed(2)} ${suffixes[i]}';
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: colorScheme.primaryContainer.withValues(alpha: 0.34),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.dns, color: colorScheme.onPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('summary'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Server counts
            Row(
              children: [
                _buildStatItem(
                  context,
                  tr('total'),
                  totalServers.toString(),
                  colorScheme.primary,
                ),
                const SizedBox(width: 10),
                _buildStatItem(
                  context,
                  tr('online'),
                  onlineServers.toString(),
                  Colors.green,
                ),
                const SizedBox(width: 10),
                _buildStatItem(
                  context,
                  tr('offline'),
                  offlineServers.toString(),
                  Colors.red,
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Network stats
            _buildSummaryInfo(
              context,
              Icons.network_check,
              tr('bandwidth'),
              '${formatBytes(totalBandwidth)}/s',
            ),
            const SizedBox(height: 8),
            _buildSummaryInfo(
              context,
              Icons.data_usage,
              tr('traffic'),
              '↑${formatBytes(totalSent.toDouble())} / ↓${formatBytes(totalRecv.toDouble())}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryInfo(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            '$label:',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  // ...

  Future<void> _subscribeToRealtime() async {
    try {
      final pb = PocketBaseService().pb;
      pb.collection('systems').subscribe('*', (e) {
        if (!mounted) return;

        if (e.action == 'create') {
          setState(() {
            _systems.insert(0, System.fromRecord(e.record!));
          });
        } else if (e.action == 'update') {
          debugPrint('REALTIME EVENT: ${e.record!.data}');
          final updatedSystem = System.fromRecord(e.record!);
          debugPrint(
            'UPDATED STATS: CPU=${updatedSystem.cpuPercent}, RAM=${updatedSystem.memoryPercent}',
          );

          setState(() {
            final index = _systems.indexWhere((s) => s.id == e.record!.id);
            if (index != -1) {
              final oldSystem = _systems[index];
              _checkAlerts(oldSystem, updatedSystem);
              _systems[index] = updatedSystem;
              _sortSystems();
            }
          });
        } else if (e.action == 'delete') {
          setState(() {
            _systems.removeWhere((s) => s.id == e.record!.id);
          });
        }
      });

      pb.collection('system_stats').subscribe('*', (e) {
        if (!mounted || e.action != 'create') return;

        final record = e.record;
        final systemId = record?.data['system']?.toString();
        final stats = record?.data['stats'];
        if (systemId == null || stats is! Map) return;

        final newTraffic = _extractTrafficTotals(stats);
        final hasGpu = (stats['g'] is Map) && (stats['g'] as Map).isNotEmpty;

        setState(() {
          if (newTraffic != null) {
            _cumulativeTraffic[systemId] = newTraffic;
          }
          _systemsWithGpu[systemId] = hasGpu;
        });
      });
    } catch (e) {
      debugPrint('Realtime subscription failed: $e');
    }
  }

  List<int>? _extractTrafficTotals(Map stats) {
    final ni = stats['ni'];
    if (ni is! Map) return null;

    int totalSent = 0;
    int totalRecv = 0;
    ni.forEach((key, value) {
      if (value is List && value.length >= 4) {
        totalSent += ((value[2] is num) ? (value[2] as num).toInt() : 0);
        totalRecv += ((value[3] is num) ? (value[3] as num).toInt() : 0);
      }
    });

    return [totalSent, totalRecv];
  }

  void _triggerAlert(System system, String title, String body, String type) {
    // Show local notification
    NotificationService().showNotification(
      id: system.id.hashCode,
      title: title,
      body: body,
    );

    // Save to history
    AlertManager().addAlert(title, body, type, system.name);
  }

  Future<void> _unsubscribeFromRealtime() async {
    try {
      final pb = PocketBaseService().pb;
      await pb.collection('systems').unsubscribe('*');
      await pb.collection('system_stats').unsubscribe('*');
    } catch (_) {}
  }

  void _logout() async {
    final pb = PocketBaseService().pb;
    pb.authStore.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pb_url');
    await PinService().removePin();

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface.withValues(alpha: 0.92),
        title: Text(tr('dashboard')),
        actions: [
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort by',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.sort_by_alpha),
                        title: Text(tr('sort_name')),
                        trailing: _currentSort == SortOption.name
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _currentSort = SortOption.name;
                            _sortSystems();
                          });
                          Navigator.pop(context);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.memory),
                        title: Text(tr('sort_cpu')),
                        trailing: _currentSort == SortOption.cpu
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _currentSort = SortOption.cpu;
                            _sortSystems();
                          });
                          Navigator.pop(context);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.storage),
                        title: Text(tr('sort_ram')),
                        trailing: _currentSort == SortOption.ram
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _currentSort = SortOption.ram;
                            _sortSystems();
                          });
                          Navigator.pop(context);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.donut_large),
                        title: Text(
                          tr('disk'),
                        ), // reused translation or key 'disk'
                        trailing: _currentSort == SortOption.disk
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _currentSort = SortOption.disk;
                            _sortSystems();
                          });
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
          Consumer<AlertManager>(
            builder: (context, alertManager, child) {
              return IconButton(
                icon: Badge(
                  isLabelVisible: alertManager.alerts.isNotEmpty,
                  smallSize: 10,
                  child: const Icon(Icons.notifications),
                ),
                tooltip: 'Alerts',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AlertsScreen()),
                  );
                },
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle),
            tooltip: 'menu_user'.tr(),
            onSelected: (String value) {
              switch (value) {
                case 'user':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UserInfoScreen()),
                  );
                  break;
                case 'theme':
                  final provider = Provider.of<AppProvider>(
                    context,
                    listen: false,
                  );
                  provider.toggleTheme(provider.themeMode != ThemeMode.dark);
                  break;
                case 'language':
                  // Show language selector
                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return SimpleDialog(
                        title: Text('select_language'.tr()),
                        children: [
                          SimpleDialogOption(
                            onPressed: () {
                              context.setLocale(const Locale('en'));
                              Navigator.pop(context);
                            },
                            child: const Text('🇺🇸 English'),
                          ),
                          SimpleDialogOption(
                            onPressed: () {
                              context.setLocale(const Locale('ru'));
                              Navigator.pop(context);
                            },
                            child: const Text('🇷🇺 Русский'),
                          ),
                          SimpleDialogOption(
                            onPressed: () {
                              context.setLocale(const Locale('zh', 'CN'));
                              Navigator.pop(context);
                            },
                            child: const Text('🇨🇳 简体中文'),
                          ),
                        ],
                      );
                    },
                  );
                  break;
                case 'appearance':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AppearanceScreen()),
                  );
                  break;
                case 'logout':
                  _logout();
                  break;
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'user',
                child: ListTile(
                  leading: const Icon(Icons.person),
                  title: Text('menu_user'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'theme',
                child: ListTile(
                  leading: Icon(
                    Provider.of<AppProvider>(
                              context,
                              listen: false,
                            ).themeMode ==
                            ThemeMode.dark
                        ? Icons.light_mode
                        : Icons.dark_mode,
                  ),
                  title: Text('menu_theme'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'appearance',
                child: ListTile(
                  leading: const Icon(Icons.view_quilt),
                  title: Text('appearance'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'language',
                child: ListTile(
                  leading: const Icon(Icons.language),
                  title: Text('menu_language'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(
                  leading: const Icon(Icons.logout),
                  title: Text(tr('logout')),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colorScheme.primaryContainer.withValues(alpha: 0.18),
              colorScheme.surface,
              colorScheme.surface,
            ],
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _isOffline
            ? _buildOfflineWidget()
            : _error != null
            ? Center(
                child: Text(
                  _error!,
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            : RefreshIndicator(
                onRefresh: _fetchSystems,
                child: Builder(
                  builder: (context) {
                    final isDetailed = Provider.of<AppProvider>(
                      context,
                    ).isDetailed;
                    // In detailed mode, add summary card at index 0
                    final itemCount = isDetailed
                        ? _systems.length + 1
                        : _systems.length;

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        // Show summary card at index 0 in detailed mode
                        if (isDetailed && index == 0) {
                          return _buildSummaryCard(context);
                        }

                        // Adjust index for systems list
                        final sysIndex = isDetailed ? index - 1 : index;
                        final system = _systems[sysIndex];
                        final traffic = _cumulativeTraffic[system.id];
                        final hasGpu =
                            _systemsWithGpu[system.id] ?? system.gpuPercent != null;
                        return _SystemCard(
                          system: system,
                          isDetailed: isDetailed,
                          cumulativeTraffic: traffic,
                          hasGpu: hasGpu,
                        );
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _SystemCard extends StatelessWidget {
  final System system;
  final bool isDetailed;
  final List<int>? cumulativeTraffic; // [sent, recv]
  final bool hasGpu;

  const _SystemCard({
    required this.system,
    this.isDetailed = false,
    this.cumulativeTraffic,
    this.hasGpu = false,
  });

  String _formatBytes(double bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var i = 0;
    while (bytes >= 1024 && i < suffixes.length - 1) {
      bytes /= 1024;
      i++;
    }
    return '${bytes.toStringAsFixed(2)} ${suffixes[i]}';
  }

  String _formatUptime(int seconds) {
    if (seconds <= 0) return '-';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  Color _getStatusColor(double usage) {
    if (usage < 50) return Colors.green;
    if (usage < 80) return Colors.orange;
    return Colors.red;
  }

  Widget _getOsIcon(String? os) {
    if (os != null && os.toLowerCase().contains('windows')) {
      return Image.asset('assets/windows.png', height: 18, width: 18);
    }
    // Default to Linux icon for all others (including null) as requested
    return Image.asset('assets/linux.png', height: 18, width: 18);
  }

  @override
  Widget build(BuildContext context) {
    if (isDetailed) return _buildDetailedCard(context);
    return _buildSimpleCard(context);
  }

  Widget _buildDetailedCard(BuildContext context) {
    // Keys from Beszel source (internal/entities/system/system.go):
    // Info struct (stored in 'systems' collection):
    //   la: LoadAvg [1m, 5m, 15m] (array of 3 floats)
    //   sv: Services [total, failed] (array of 2 ints)
    //   b:  Bandwidth (float64, combined rate in bytes/s)
    //   bb: BandwidthBytes (uint64, cumulative TOTAL = sent + recv combined)
    //
    // Stats struct (stored in 'system_stats' collection):
    //   b: Bandwidth ([2]uint64 = [sent bytes, recv bytes] cumulative)
    //   ns/nr: NetworkSent/NetworkRecv (real-time rate, bytes/s)

    String load = '0.00 0.00 0.00';
    String network = '0 B/s';
    String services = '0';
    String totalTraffic = '加载中...'; // Loading...
    int serviceTotal = 0;

    try {
      // Load Average (la: [3]float64)
      if (system.info['la'] != null) {
        final l = system.info['la'];
        if (l is List) {
          load = l
              .map((v) => (v is num) ? v.toStringAsFixed(2) : v.toString())
              .join(' ');
        } else {
          load = l.toString();
        }
      }

      // Real-time Network Speed (bb: combined bytes/s rate)
      // Note: info['b'] is not set by agent, so we use 'bb' which is bytesSentPerSec + bytesRecvPerSec
      if (system.info['bb'] != null && system.info['bb'] is num) {
        final bb = (system.info['bb'] as num).toDouble();
        network = '${_formatBytes(bb)}/s';
      }

      // Services (sv: [total, failed])
      int serviceFailed = 0;
      if (system.info['sv'] != null) {
        final sv = system.info['sv'];
        if (sv is List && sv.isNotEmpty) {
          serviceTotal = (sv[0] is num) ? (sv[0] as num).toInt() : 0;
          serviceFailed = (sv.length > 1 && sv[1] is num)
              ? (sv[1] as num).toInt()
              : 0;
          if (serviceTotal > 0) {
            services = '$serviceTotal (Fail: $serviceFailed)';
          }
        }
      }

      // Total Traffic (from system_stats via cumulativeTraffic)
      // cumulativeTraffic = [sent, recv] from Stats.b
      if (cumulativeTraffic != null && cumulativeTraffic!.length >= 2) {
        final sent = cumulativeTraffic![0];
        final recv = cumulativeTraffic![1];
        totalTraffic =
            '↑${_formatBytes(sent.toDouble())} / ↓${_formatBytes(recv.toDouble())}';
      } else {
        // Fallback: use bb (combined total) if cumulativeTraffic not loaded yet
        if (system.info['bb'] != null && system.info['bb'] is num) {
          final bb = (system.info['bb'] as num).toDouble();
          totalTraffic = '总计: ${_formatBytes(bb)}';
        }
      }
    } catch (_) {}

    // Uptime (u: seconds since boot)
    String uptime = '-';
    if (system.info['u'] != null && system.info['u'] is num) {
      uptime = _formatUptime((system.info['u'] as num).toInt());
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SystemDetailScreen(system: system),
            ),
          );
        },
        onLongPress: () {
          // Debug: show raw data
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: Text('Debug: ${system.name}'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '=== info ===',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SelectableText(system.info.toString()),
                    const SizedBox(height: 16),
                    const Text(
                      '=== cumulativeTraffic ===',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SelectableText(cumulativeTraffic?.toString() ?? 'null'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(detailed: true),
              const SizedBox(height: 16),
              _buildProgressBar(
                context,
                'CPU',
                system.cpuPercent,
                Icons.memory,
              ),
              const SizedBox(height: 8),
              _buildProgressBar(
                context,
                'RAM',
                system.memoryPercent,
                Icons.storage,
              ),
              const SizedBox(height: 8),
              _buildProgressBar(
                context,
                'Disk',
                system.diskPercent,
                Icons.donut_large,
              ),
              const SizedBox(height: 8),
              if (hasGpu) ...[
                _buildProgressBar(
                  context,
                  'GPU',
                  system.gpuPercent ?? 0.0,
                  Icons.graphic_eq,
                ),
                const SizedBox(height: 8),
              ],
              _buildInfoRow(context, Icons.speed, tr('load'), load),
              const SizedBox(height: 4),
              _buildInfoRow(
                context,
                Icons.network_check,
                tr('network'),
                network,
              ),
              const SizedBox(height: 4),
              _buildInfoRow(
                context,
                Icons.data_usage,
                tr('traffic'),
                totalTraffic,
              ),
              const SizedBox(height: 4),
              _buildInfoRow(context, Icons.schedule, tr('uptime'), uptime),
              // Only show services row if there are services (non-Docker agent)
              if (serviceTotal > 0) ...[
                const SizedBox(height: 4),
                _buildInfoRow(
                  context,
                  Icons.miscellaneous_services,
                  tr('services'),
                  services,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSimpleCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SystemDetailScreen(system: system),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(18.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(detailed: false),
              const SizedBox(height: 4),
              Text(
                system.host,
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _buildStat(tr('cpu'), system.cpuPercent, Icons.memory),
                  const SizedBox(width: 10),
                  _buildStat(tr('ram'), system.memoryPercent, Icons.storage),
                  const SizedBox(width: 10),
                  _buildStat(tr('disk'), system.diskPercent, Icons.donut_large),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader({required bool detailed}) {
    final statusColor = system.status == 'up' ? Colors.green : Colors.red;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _getOsIcon(system.os),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            system.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: statusColor.withValues(alpha: 0.26)),
          ),
          child: Text(
            system.status.toUpperCase(),
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar(
    BuildContext context,
    String label,
    double value,
    IconData icon,
  ) {
    final color = _getStatusColor(value);
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Row(
            children: [
              Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value / 100,
              color: color,
              backgroundColor: colorScheme.surfaceContainerHighest,
              minHeight: 10,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          child: Text(
            '${value.toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text('$label: ', style: TextStyle(color: colorScheme.onSurfaceVariant)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  Widget _buildStat(String label, double value, IconData icon) {
    final color = _getStatusColor(value);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(
              '${value.toStringAsFixed(1)}%',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
