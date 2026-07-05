import 'dart:async';

import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:beszel_pro/screens/system_details_screen.dart';

class SystemDetailScreen extends StatefulWidget {
  final System system;

  const SystemDetailScreen({super.key, required this.system});

  @override
  State<SystemDetailScreen> createState() => _SystemDetailScreenState();
}

class _SystemDetailScreenState extends State<SystemDetailScreen> {
  // Selected category: 0=CPU, 1=Memory, 2=Disk, 3=Network
  int _selectedCategory = 0;

  // Chart data
  List<FlSpot> _cpuSpots = [];
  List<FlSpot> _ramSpots = [];
  List<FlSpot> _diskSpots = [];
  List<FlSpot> _netSpots = [];
  List<FlSpot> _gpuPowerSpots = [];
  List<FlSpot> _gpuUtilSpots = [];
  List<FlSpot> _gpuVramSpots = [];

  // Latest stats from system_stats
  Map<String, dynamic>? _latestStats;

  // Per-core CPU usage
  List<int> _cpuCoresUsage = [];

  // Containers and systemd services
  List<Map<String, dynamic>> _containers = [];
  List<Map<String, dynamic>> _systemdServices = [];
  bool _containersLoading = true;
  bool _systemdLoading = true;
  String _chartTime = '1h';
  bool _chartLoading = true;
  int _chartLoadRequestId = 0;
  Future<void> Function()? _rtMetricsUnsubscribe;
  Timer? _realtimeWatchdog;
  bool _rtMetricsHealthy = false;
  int _realtimeReconnectAttempts = 0;
  DateTime? _lastRealtimeEventAt;

  bool _isLoading = true;
  // System details from PocketBase (hostname, OS, etc.)
  Map<String, dynamic>? _systemDetails;

  @override
  void initState() {
    super.initState();
    _fetchHistory(requestId: _chartLoadRequestId);
    _fetchSystemDetails();
    _fetchContainers();
    _fetchSystemdServices();
    _subscribeToRealtime();
  }

  @override
  void dispose() {
    _unsubscribeFromRealtime();
    _realtimeWatchdog?.cancel();
    super.dispose();
  }

  Future<void> _subscribeToRealtime() async {
    try {
      final pb = PocketBaseService().pb;
      await _subscribeSystemStats(pb);
      await _subscribeRtMetrics(pb);
    } catch (e) {
      debugPrint('Subscription failed: $e');
      _rtMetricsHealthy = false;
    }
  }

  Future<void> _unsubscribeFromRealtime() async {
    try {
      await _rtMetricsUnsubscribe?.call();
      final pb = PocketBaseService().pb;
      await pb.collection('system_stats').unsubscribe('*');
    } catch (_) {}
  }

  Future<void> _subscribeSystemStats(PocketBase pb) async {
    await pb.collection('system_stats').subscribe(
      '*',
      (e) {
        if (!mounted || e.action != 'create') return;
        if (e.record?.data['system'] != widget.system.id) return;
        final stats = e.record?.data['stats'];
        if (stats is! Map) return;

        final activeType = _currentChartType;
        final recordType = e.record?.data['type']?.toString();
        if (_chartLoading) return;
        if (_chartTime == '1m') {
          if (!_rtMetricsHealthy) {
            setState(() {
              _appendStatsSnapshot(
                stats.cast<String, dynamic>(),
                e.record?.created,
              );
            });
          }
          return;
        }

        if (recordType == activeType) {
          setState(() {
            _appendStatsSnapshot(
              stats.cast<String, dynamic>(),
              e.record?.created,
            );
          });
        }
      },
      filter: 'system = "${widget.system.id}"',
    );
  }

  Future<void> _subscribeRtMetrics(PocketBase pb) async {
    _rtMetricsHealthy = true;
    _realtimeReconnectAttempts = 0;
    _lastRealtimeEventAt = DateTime.now();
    _realtimeWatchdog?.cancel();
    _realtimeWatchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkRealtimeHealth();
    });

    _rtMetricsUnsubscribe = await pb.realtime.subscribe(
      'rt_metrics',
      (e) {
        if (!mounted) return;
        final payload = e.jsonData();
        final stats = payload['stats'];
        if (stats is! Map) {
          return;
        }

        _lastRealtimeEventAt = DateTime.now();
        _rtMetricsHealthy = true;
        _realtimeReconnectAttempts = 0;
        if (_chartTime != '1m' || _chartLoading) {
          return;
        }
        setState(() {
          _latestStats = stats.cast<String, dynamic>();
          _appendStatsSnapshot(
            stats.cast<String, dynamic>(),
            DateTime.now().toIso8601String(),
          );
        });
      },
      query: {'system': widget.system.id},
    );
  }

  Future<void> _checkRealtimeHealth() async {
    if (!mounted || !_rtMetricsHealthy) return;
    final last = _lastRealtimeEventAt;
    if (last == null) return;

    final stale = DateTime.now().difference(last).inSeconds >= 5;
    if (!stale) return;

    _realtimeReconnectAttempts += 1;
    if (_realtimeReconnectAttempts < 3) {
      debugPrint('rt_metrics stale, resubscribing (${_realtimeReconnectAttempts})');
      try {
        await _rtMetricsUnsubscribe?.call();
      } catch (_) {}
      try {
        final pb = PocketBaseService().pb;
        await _subscribeRtMetrics(pb);
      } catch (e) {
        debugPrint('rt_metrics resubscribe failed: $e');
      }
      return;
    }

    debugPrint('rt_metrics stale, falling back to system_stats collection');
    _rtMetricsHealthy = false;
  }

  List<_ChartTimeOption> get _chartTimeOptions {
    final options = <_ChartTimeOption>[
      if (_supportsRealtime1m)
        const _ChartTimeOption('1m', '1m', Duration(minutes: 1)),
      const _ChartTimeOption('1h', '1m', Duration(hours: 1)),
      const _ChartTimeOption('1d', '20m', Duration(days: 1)),
      const _ChartTimeOption('1w', '120m', Duration(days: 7)),
      const _ChartTimeOption('1M', '480m', Duration(days: 30)),
    ];
    return options;
  }

  bool get _supportsRealtime1m {
    return _compareSemVer(
          widget.system.info['v']?.toString() ?? '',
          '0.13.0',
        ) >=
        0;
  }

  _ChartTimeOption get _currentChartRange {
    return _chartTimeOptions.firstWhere(
      (option) => option.key == _chartTime,
      orElse: () => _chartTimeOptions.first,
    );
  }

  String get _currentChartType => _currentChartRange.type;

  int get _maxChartPoints {
    switch (_chartTime) {
      case '1m':
        return 60;
      case '1h':
        return 3600;
      case '1d':
        return 72;
      case '1w':
        return 84;
      case '1M':
        return 90;
      default:
        return 120;
    }
  }

  Future<void> _setChartTime(String key) async {
    final normalized = _chartTimeOptions.any((option) => option.key == key)
        ? key
        : _chartTimeOptions.first.key;
    if (normalized == _chartTime) {
      return;
    }
    final requestId = ++_chartLoadRequestId;
    setState(() {
      _chartTime = normalized;
      _chartLoading = true;
    });
    await _fetchHistory(requestId: requestId);
  }

  String _pbTimestamp(DateTime date) {
    final utc = date.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
  }

  int _compareSemVer(String a, String b) {
    List<int> parts(String value) {
      return value
          .split('.')
          .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
          .toList();
    }

    final left = parts(a);
    final right = parts(b);
    for (var i = 0; i < 3; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  void _addSpot(List<FlSpot> spots, double x, double y) {
    spots.add(FlSpot(x, y));
    if (spots.length > _maxChartPoints) {
      spots.removeAt(0);
    }
  }

  void _appendStatsSnapshot(Map<String, dynamic> stats, dynamic createdAt) {
    final DateTime time = createdAt is DateTime
        ? createdAt.toLocal()
        : createdAt is String
        ? DateTime.parse(createdAt).toLocal()
        : DateTime.now();
    final double xVal = time.millisecondsSinceEpoch.toDouble();

    double getDouble(dynamic val) {
      if (val is int) return val.toDouble();
      if (val is double) return val;
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    void updateCoreUsage(dynamic coreData) {
      if (coreData is List) {
        _cpuCoresUsage = coreData.map((v) => (v is num) ? v.toInt() : 0).toList();
      } else if (coreData is num) {
        _cpuCoresUsage = List.filled(coreData.toInt(), 0);
      }
    }

    _addSpot(_cpuSpots, xVal, getDouble(stats['cpu']));
    _addSpot(_ramSpots, xVal, getDouble(stats['mp']));
    _addSpot(_diskSpots, xVal, getDouble(stats['dp']));

    final netVal = (getDouble(stats['ns']) + getDouble(stats['nr'])) / 1024;
    _addSpot(_netSpots, xVal, netVal);

    updateCoreUsage(stats['cpus'] ?? stats['c']);

    double gpuPowerTotal = 0;
    double gpuUtilTotal = 0;
    int gpuCount = 0;
    double gpuVramUsed = 0;
    final gpus = stats['g'];
    if (gpus is Map) {
      gpus.forEach((key, value) {
        if (value is Map) {
          if (value['p'] != null && value['p'] is num) {
            gpuPowerTotal += (value['p'] as num).toDouble();
          }
          if (value['u'] != null && value['u'] is num) {
            gpuUtilTotal += (value['u'] as num).toDouble();
            gpuCount++;
          }
          if (value['mu'] != null && value['mu'] is num) {
            gpuVramUsed += (value['mu'] as num).toDouble();
          }
        }
      });
    }

    _addSpot(_gpuPowerSpots, xVal, gpuPowerTotal);
    if (gpuCount > 0) {
      _addSpot(_gpuUtilSpots, xVal, gpuUtilTotal / gpuCount);
    }
    if (gpuVramUsed > 0) {
      _addSpot(_gpuVramSpots, xVal, _mbToGb(gpuVramUsed));
    }
  }

  Future<void> _fetchHistory({required int requestId}) async {
    try {
      final pb = PocketBaseService().pb;
      final range = _currentChartRange;
      final since = _pbTimestamp(DateTime.now().subtract(range.duration));
      final records = await pb.collection('system_stats').getFullList(
        batch: 500,
        filter: 'system = "${widget.system.id}" && type = "${range.type}" && created > "$since"',
        sort: 'created',
      );

      final reversed = records.reversed.toList();

      final cpu = <FlSpot>[];
      final ram = <FlSpot>[];
      final disk = <FlSpot>[];
      final net = <FlSpot>[];
      final gpu = <FlSpot>[];
      final gpuUtilSpots = <FlSpot>[];
      final vram = <FlSpot>[];

      double getDouble(dynamic val) {
        if (val is int) return val.toDouble();
        if (val is double) return val;
        if (val is String) return double.tryParse(val) ?? 0.0;
        return 0.0;
      }

      for (final r in reversed) {
        final createdAt = r.data['created'];
        final DateTime time = createdAt is String
            ? DateTime.parse(createdAt).toLocal()
            : DateTime.now();
        final double xVal = time.millisecondsSinceEpoch.toDouble();

        double extract(String key) {
          final stats = r.data['stats'];
          if (stats is Map && stats.containsKey(key)) {
            return getDouble(stats[key]);
          }
          return 0.0;
        }

        cpu.add(FlSpot(xVal, extract('cpu')));
        ram.add(FlSpot(xVal, extract('mp')));
        disk.add(FlSpot(xVal, extract('dp')));

        final netVal = (extract('ns') + extract('nr')) / 1024;
        net.add(FlSpot(xVal, netVal));

        double gpuPower = 0;
        double gpuUtilTotal = 0;
        int gpuCount = 0;
        double gpuVramUsed = 0;
        final stats = r.data['stats'];
        if (stats is Map && stats['g'] is Map) {
          final gpus = stats['g'] as Map;
          gpus.forEach((key, value) {
            if (value is Map) {
              if (value['p'] != null && value['p'] is num) {
                gpuPower += (value['p'] as num).toDouble();
              }
              if (value['u'] != null && value['u'] is num) {
                gpuUtilTotal += (value['u'] as num).toDouble();
                gpuCount++;
              }
              if (value['mu'] != null && value['mu'] is num) {
                gpuVramUsed += (value['mu'] as num).toDouble();
              }
            }
          });
        }
        gpu.add(FlSpot(xVal, gpuPower));
        if (gpuCount > 0) {
          gpuUtilSpots.add(FlSpot(xVal, gpuUtilTotal / gpuCount));
        }
        if (gpuVramUsed > 0) {
          vram.add(FlSpot(xVal, _mbToGb(gpuVramUsed)));
        }
      }

      if (records.isNotEmpty) {
        final latest = records.last.data['stats'];
        if (latest is Map) {
          _latestStats = Map<String, dynamic>.from(latest);
          final cpus = latest['cpus'];
          if (cpus is List) {
            _cpuCoresUsage = cpus.map((v) => (v is num) ? v.toInt() : 0).toList();
          }
        }
      }

      if (mounted && requestId == _chartLoadRequestId) {
        setState(() {
          _cpuSpots = cpu;
          _ramSpots = ram;
          _diskSpots = disk;
          _netSpots = net;
          _gpuPowerSpots = gpu;
          _gpuUtilSpots = gpuUtilSpots;
          _gpuVramSpots = vram;
          _chartLoading = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && requestId == _chartLoadRequestId) {
        setState(() {
          _chartLoading = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchSystemDetails() async {
    try {
      final details = await PocketBaseService().fetchSystemDetails(
        widget.system.id,
      );
      if (mounted) {
        setState(() {
          _systemDetails = details;
        });
      }
    } catch (e) {}
  }

  Future<void> _fetchContainers() async {
    try {
      final pb = PocketBaseService().pb;
      final result = await pb.collection('containers').getList(
        page: 1,
        perPage: 200,
        filter: 'system = "${widget.system.id}"',
        sort: '-updated',
      );
      if (!mounted) return;
      setState(() {
        _containers = result.items
            .map((record) => Map<String, dynamic>.from(record.data))
            .toList();
        _containersLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _containersLoading = false;
      });
    }
  }

  Future<void> _fetchSystemdServices() async {
    try {
      final pb = PocketBaseService().pb;
      final result = await pb.collection('systemd_services').getList(
        page: 1,
        perPage: 2000,
        filter: 'system = "${widget.system.id}"',
        sort: 'name',
      );
      if (!mounted) return;
      setState(() {
        _systemdServices = result.items
            .map((record) => Map<String, dynamic>.from(record.data))
            .toList();
        _systemdLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _systemdLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.system.name),
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _chartTimeOptions.any((option) => option.key == _chartTime)
                    ? _chartTime
                    : _chartTimeOptions.first.key,
                icon: const Icon(Icons.expand_more),
                style: Theme.of(context).textTheme.labelMedium,
                dropdownColor: Theme.of(context).colorScheme.surface,
                isDense: true,
                onChanged: (value) {
                  if (value != null) {
                    _setChartTime(value);
                  }
                },
                items: _chartTimeOptions
                    .map(
                      (option) => DropdownMenuItem<String>(
                        value: option.key,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: tr('details'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SystemDetailsScreen(system: widget.system),
                ),
              );
            },
          ),
        ],
      ),
      body: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      children: [
        // Sidebar
        SizedBox(width: 140, child: _buildSidebar()),
        const VerticalDivider(width: 1),
        // Main content
        Expanded(child: _buildMainPanel()),
      ],
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        // Horizontal category tabs
        SizedBox(height: 80, child: _buildHorizontalTabs()),
        const Divider(height: 1),
        // Main content
        Expanded(child: _buildMainPanel()),
      ],
    );
  }

  Widget _buildSidebar() {
    return Container(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _buildSidebarItem(0, Icons.memory, 'CPU', widget.system.cpuPercent),
          _buildSidebarItem(
            1,
            Icons.storage,
            tr('ram'),
            widget.system.memoryPercent,
          ),
          _buildSidebarItem(
            2,
            Icons.disc_full,
            tr('disk'),
            widget.system.diskPercent,
          ),
          _buildSidebarItem(3, Icons.network_check, tr('network'), null),
          _buildSidebarItem(4, Icons.graphic_eq, 'GPU', null),
          _buildSidebarItem(5, Icons.view_in_ar, tr('containers'), null),
          _buildSidebarItem(6, Icons.settings_applications, tr('systemd'), null),
        ],
      ),
    );
  }

  Widget _buildSidebarItem(
    int index,
    IconData icon,
    String label,
    double? value,
  ) {
    final isSelected = _selectedCategory == index;
    final color = isSelected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);

    return InkWell(
      onTap: () => setState(() => _selectedCategory = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
          border: isSelected
              ? Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(fontWeight: FontWeight.w600, color: color),
                ),
              ],
            ),
            if (value != null) ...[
              const SizedBox(height: 4),
              Text(
                '${value.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: value / 100,
                backgroundColor: Colors.grey.withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation(_getUsageColor(value)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalTabs() {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        _buildTabItem(0, Icons.memory, 'CPU', widget.system.cpuPercent),
        _buildTabItem(1, Icons.storage, tr('ram'), widget.system.memoryPercent),
        _buildTabItem(
          2,
          Icons.disc_full,
          tr('disk'),
          widget.system.diskPercent,
        ),
        _buildTabItem(3, Icons.network_check, tr('network'), null),
        if ((_latestStats?['g'] as Map?)?.isNotEmpty ?? false)
          _buildTabItem(4, Icons.graphic_eq, 'GPU', null),
        _buildTabItem(5, Icons.view_in_ar, tr('containers'), null),
        _buildTabItem(6, Icons.settings_applications, tr('systemd'), null),
      ],
    );
  }

  Widget _buildTabItem(int index, IconData icon, String label, double? value) {
    final isSelected = _selectedCategory == index;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => setState(() => _selectedCategory = index),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 90,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 2),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (value != null)
                Text(
                  '${value.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainPanel() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (_selectedCategory) {
      case 0:
        return _buildCpuPanel();
      case 1:
        return _buildMemoryPanel();
      case 2:
        return _buildDiskPanel();
      case 3:
        return _buildNetworkPanel();
      case 4:
        return _buildGpuPanel();
      case 5:
        return _buildContainersPanel();
      case 6:
        return _buildSystemdPanel();
      default:
        return _buildCpuPanel();
    }
  }

  Widget _buildCpuPanel() {
    // Get CPU model from system info
    String cpuModel =
        _systemDetails?['cpu']?.toString() ??
        widget.system.info['m']?.toString() ??
        'Unknown';
    int cores = _cpuCoresUsage.isNotEmpty
        ? _cpuCoresUsage.length
        : (widget.system.info['c'] is num
              ? (widget.system.info['c'] as num).toInt()
              : 0);
    int threads = widget.system.info['t'] is num
        ? (widget.system.info['t'] as num).toInt()
        : 0;

    // Uptime
    int uptimeSeconds = widget.system.info['u'] is num
        ? (widget.system.info['u'] as num).toInt()
        : 0;
    String uptime = _formatUptime(uptimeSeconds);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Text(
                'CPU',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  cpuModel,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '60 ${tr('seconds')} ${tr('utilization')} %',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),

          // Main chart
          _buildMiniChart(
            _cpuSpots,
            Colors.blue,
            isPercent: true,
            height: 150,
            loading: _chartLoading,
            chartTime: _chartTime,
          ),
          const SizedBox(height: 24),

          // Per-core CPU grid
          if (_cpuCoresUsage.isNotEmpty) ...[
            Text(
              'CPU ${tr('cores')}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _buildCpuCoreGrid(),
            const SizedBox(height: 24),
          ],

          // Stats grid
          _buildStatsGrid([
            _StatItem(
              tr('utilization'),
              '${widget.system.cpuPercent.toStringAsFixed(1)}%',
            ),
            _StatItem(tr('cores'), cores.toString()),
            _StatItem(tr('threads'), threads.toString()),
            _StatItem(tr('uptime'), uptime),
          ]),
        ],
      ),
    );
  }

  Widget _buildMemoryPanel() {
    double memTotal = _latestStats?['m'] is num
        ? (_latestStats!['m'] as num).toDouble()
        : 0;
    double memUsed = _latestStats?['mu'] is num
        ? (_latestStats!['mu'] as num).toDouble()
        : 0;
    double memBuffCache = _latestStats?['mb'] is num
        ? (_latestStats!['mb'] as num).toDouble()
        : 0;
    double swapTotal = _latestStats?['s'] is num
        ? (_latestStats!['s'] as num).toDouble()
        : 0;
    double swapUsed = _latestStats?['su'] is num
        ? (_latestStats!['su'] as num).toDouble()
        : 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('ram'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${memUsed.toStringAsFixed(2)} / ${memTotal.toStringAsFixed(2)} GB',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),

          _buildMiniChart(
            _ramSpots,
            Colors.purple,
            isPercent: true,
            height: 150,
            loading: _chartLoading,
            chartTime: _chartTime,
          ),
          const SizedBox(height: 24),

          _buildStatsGrid([
            _StatItem(tr('total'), '${memTotal.toStringAsFixed(2)} GB'),
            _StatItem(tr('used'), '${memUsed.toStringAsFixed(2)} GB'),
            _StatItem('Buffer/Cache', '${memBuffCache.toStringAsFixed(2)} GB'),
            _StatItem(
              tr('utilization'),
              '${widget.system.memoryPercent.toStringAsFixed(1)}%',
            ),
            if (swapTotal > 0) ...[
              _StatItem(
                'Swap',
                '${swapUsed.toStringAsFixed(2)} / ${swapTotal.toStringAsFixed(2)} GB',
              ),
            ],
          ]),
        ],
      ),
    );
  }

  Widget _buildDiskPanel() {
    double diskTotal = _latestStats?['d'] is num
        ? (_latestStats!['d'] as num).toDouble()
        : 0;
    double diskUsed = _latestStats?['du'] is num
        ? (_latestStats!['du'] as num).toDouble()
        : 0;
    double diskRead = _latestStats?['dr'] is num
        ? (_latestStats!['dr'] as num).toDouble()
        : 0;
    double diskWrite = _latestStats?['dw'] is num
        ? (_latestStats!['dw'] as num).toDouble()
        : 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('disk'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${diskUsed.toStringAsFixed(2)} / ${diskTotal.toStringAsFixed(2)} GB',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),

          _buildMiniChart(
            _diskSpots,
            Colors.orange,
            isPercent: true,
            height: 150,
            loading: _chartLoading,
            chartTime: _chartTime,
          ),
          const SizedBox(height: 24),

          _buildStatsGrid([
            _StatItem(tr('total'), '${diskTotal.toStringAsFixed(2)} GB'),
            _StatItem(tr('used'), '${diskUsed.toStringAsFixed(2)} GB'),
            _StatItem(
              tr('utilization'),
              '${widget.system.diskPercent.toStringAsFixed(1)}%',
            ),
            _StatItem('Read', '${diskRead.toStringAsFixed(2)} MB/s'),
            _StatItem('Write', '${diskWrite.toStringAsFixed(2)} MB/s'),
          ]),
        ],
      ),
    );
  }

  Widget _buildNetworkPanel() {
    // Network interfaces - contains [upDelta, downDelta, totalSent, totalRecv]
    Map<String, dynamic>? ni = _latestStats?['ni'];

    // Calculate total network speed from all interfaces
    double totalSent = 0;
    double totalRecv = 0;
    if (ni != null) {
      ni.forEach((key, value) {
        if (value is List && value.length >= 2) {
          totalSent += (value[0] is num) ? (value[0] as num).toDouble() : 0;
          totalRecv += (value[1] is num) ? (value[1] as num).toDouble() : 0;
        }
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('network'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '↑ ${_formatBytesSpeed(totalSent)}  ↓ ${_formatBytesSpeed(totalRecv)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),

          _buildMiniChart(
            _netSpots,
            Colors.green,
            isPercent: false,
            height: 150,
            loading: _chartLoading,
            chartTime: _chartTime,
          ),
          const SizedBox(height: 24),

          _buildStatsGrid([
            _StatItem('Upload', _formatBytesSpeed(totalSent)),
            _StatItem('Download', _formatBytesSpeed(totalRecv)),
          ]),

          // Network interfaces
          if (ni != null && ni.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Interfaces', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...ni.entries.map((e) {
              final data = e.value;
              if (data is List && data.length >= 4) {
                return Card(
                  child: ListTile(
                    title: Text(e.key),
                    subtitle: Text(
                      '↑ ${_formatBytes(data[2].toDouble())} / ↓ ${_formatBytes(data[3].toDouble())}',
                    ),
                    trailing: Text(
                      '${_formatBytesSpeed(data[0].toDouble())} / ${_formatBytesSpeed(data[1].toDouble())}',
                    ),
                  ),
                );
              }
              return const SizedBox();
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildContainersPanel() {
    if (_containersLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_containers.isEmpty) {
      return Center(child: Text(tr('no_data_available')));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('containers'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_containers.length} ${tr('services')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ..._containers.map((container) {
            final name = container['name']?.toString() ?? '-';
            final image = container['image']?.toString() ?? '-';
            final ports = container['ports']?.toString() ?? '-';
            final status = container['status']?.toString() ?? '-';
            final cpu = container['cpu'] is num
                ? (container['cpu'] as num).toDouble()
                : 0.0;
            final memory = container['memory'] is num
                ? (container['memory'] as num).toDouble()
                : 0.0;
            final net = container['net'] is num
                ? (container['net'] as num).toDouble()
                : 0.0;
            final health = container['health']?.toString() ?? '-';

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                title: Text(name),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(image, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text('CPU: ${cpu.toStringAsFixed(1)}%'),
                      Text('Memory: ${_formatBytes(memory)}'),
                      Text('Net: ${_formatBytesSpeed(net)}'),
                      Text('Ports: $ports'),
                      Text('Health: $health'),
                    ],
                  ),
                ),
                trailing: Text(
                  status,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                isThreeLine: true,
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildSystemdPanel() {
    if (_systemdLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_systemdServices.isEmpty) {
      return Center(child: Text(tr('no_data_available')));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('systemd'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_systemdServices.length} ${tr('services')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ..._systemdServices.map((service) {
            final name = service['name']?.toString() ?? '-';
            final state = service['state']?.toString() ?? '-';
            final sub = service['sub']?.toString() ?? '-';
            final cpu = service['cpu'] is num
                ? (service['cpu'] as num).toDouble()
                : 0.0;
            final cpuPeak = service['cpuPeak'] is num
                ? (service['cpuPeak'] as num).toDouble()
                : 0.0;
            final memory = service['memory'] is num
                ? (service['memory'] as num).toDouble()
                : 0.0;
            final memPeak = service['memPeak'] is num
                ? (service['memPeak'] as num).toDouble()
                : 0.0;
            final updated = service['updated'] is num
                ? DateTime.fromMillisecondsSinceEpoch(
                    (service['updated'] as num).toInt(),
                  )
                : null;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                title: Text(name),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('State: $state'),
                      Text('Sub: $sub'),
                      Text('CPU: ${cpu.toStringAsFixed(1)}%'),
                      Text('CPU Peak: ${cpuPeak.toStringAsFixed(1)}%'),
                      Text('Memory: ${_formatBytes(memory)}'),
                      Text('Memory Peak: ${_formatBytes(memPeak)}'),
                      if (updated != null)
                        Text(
                          'Updated: ${updated.toLocal()}',
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                isThreeLine: true,
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCpuCoreGrid() {
    // Calculate number of columns based on core count
    int crossAxisCount = 4;
    if (_cpuCoresUsage.length <= 2) {
      crossAxisCount = 2;
    } else if (_cpuCoresUsage.length <= 8) {
      crossAxisCount = 4;
    } else {
      crossAxisCount = 4;
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 1.8,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _cpuCoresUsage.length,
      itemBuilder: (context, index) {
        final usage = _cpuCoresUsage[index];
        final color = _getUsageColor(usage.toDouble());

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CPU $index',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '$usage%',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: usage / 100,
                  minHeight: 6,
                  backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMiniChart(
    List<FlSpot> spots,
    Color color, {
    required bool isPercent,
    double height = 120,
    double? maxY,
    bool loading = false,
    String chartTime = '1h',
  }) {
    double? effectiveMaxY = isPercent ? 100 : maxY;
    if (!isPercent && maxY == null && spots.isNotEmpty) {
      effectiveMaxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b) * 1.2;
      if (effectiveMaxY! < 1) effectiveMaxY = 1;
    }

    return SizedBox(
      height: height,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : spots.isEmpty
          ? Center(child: Text(tr('no_history')))
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.08),
                    Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.38),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: color.withValues(alpha: 0.14)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: LineChart(
                LineChartData(
                  minX: spots.first.x,
                  maxX: spots.length > 1 ? spots.last.x : spots.first.x + 1,
                  minY: 0,
                  maxY: effectiveMaxY,
                  clipData: const FlClipData.all(),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: isPercent
                        ? 25
                        : (effectiveMaxY != null ? effectiveMaxY / 4 : null),
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: color.withValues(alpha: 0.08),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        interval: isPercent
                            ? 25
                            : (effectiveMaxY != null ? effectiveMaxY / 4 : null),
                        getTitlesWidget: (value, meta) {
                          final label = isPercent
                              ? '${value.toInt()}%'
                              : value >= 10
                                  ? value.toStringAsFixed(0)
                                  : value.toStringAsFixed(1);
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: _chartXAxisInterval(chartTime),
                        getTitlesWidget: (value, meta) {
                          final label = _formatChartXAxisLabel(
                            DateTime.fromMillisecondsSinceEpoch(value.toInt()),
                            chartTime,
                          );
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: color,
                      barWidth: 2.5,
                      curveSmoothness: 0.25,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: color.withValues(alpha: 0.22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  double _chartXAxisInterval(String chartTime) {
    switch (chartTime) {
      case '1m':
        return 15000;
      case '1h':
        return 15 * 60 * 1000;
      case '1d':
        return 6 * 60 * 60 * 1000;
      case '1w':
        return 24 * 60 * 60 * 1000;
      case '1M':
        return 5 * 24 * 60 * 60 * 1000;
      default:
        return 15 * 60 * 1000;
    }
  }

  String _formatChartXAxisLabel(DateTime time, String chartTime) {
    String two(int value) => value.toString().padLeft(2, '0');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    switch (chartTime) {
      case '1m':
        return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
      case '1h':
      case '1d':
        return '${two(time.hour)}:${two(time.minute)}';
      case '1w':
      case '1M':
        return '${months[time.month - 1]} ${time.day}';
      default:
        return '${two(time.hour)}:${two(time.minute)}';
    }
  }

  Widget _buildStatsGrid(List<_StatItem> items) {
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: items
          .map(
            (item) => SizedBox(
              width: 150,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    item.value,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Color _getUsageColor(double usage) {
    if (usage < 50) return Colors.green;
    if (usage < 80) return Colors.orange;
    return Colors.red;
  }

  String _formatUptime(int seconds) {
    if (seconds <= 0) return '-';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (days > 0) return '${days}d ${hours}h ${mins}m';
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  String _formatBytes(double bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (bytes >= 1024 && i < suffixes.length - 1) {
      bytes /= 1024;
      i++;
    }
    return '${bytes.toStringAsFixed(2)} ${suffixes[i]}';
  }

  String _formatBytesSpeed(double bytesPerSec) {
    return '${_formatBytes(bytesPerSec)}/s';
  }

  double _mbToGb(double mb) {
    return mb / 1024;
  }

  // GPU panel
  // Look up basic specs (max VRAM in GB, max power in W) for known GPU models
  Map<String, double> _gpuSpecs(String model) {
    final lower = model.toLowerCase();
    // Known models – extend as needed
    if (lower.contains('h200')) {
      // NVIDIA H200: 141 GB VRAM, 600 W TDP
      return {'vram': 141.0, 'power': 600.0};
    }
    // Add other models here (e.g., "rtx 3080": {'vram': 10.0, 'power': 320.0})
    return {'vram': 0.0, 'power': 0.0}; // Unknown – fallback
  }

  Widget _buildGpuPanel() {
    // Latest GPU map from stats
    final Map<String, dynamic>? gpus =
        _latestStats?['g'] as Map<String, dynamic>?;
    // Compute total power from the latest snapshot
    double totalPower = 0;
    double maxVramGb = 0.0;
    double maxPowerW = 0.0;
    if (gpus != null) {
      gpus.forEach((id, gpu) {
        if (gpu is Map) {
          // Power draw (p)
          if (gpu['p'] != null && gpu['p'] is num) {
            totalPower += (gpu['p'] as num).toDouble();
          }
          // GPU model name for specs fallback
          final _gpuName = gpu['n']?.toString() ?? '';
          final _specs = _gpuSpecs(_gpuName);

          // VRAM total (mt) is reported as MB by Beszel's web UI.
          var mtVal = gpu['mt'];
          double? vramMb;
          if (mtVal is num) {
            vramMb = mtVal.toDouble();
          } else if (mtVal is String) {
            vramMb = double.tryParse(mtVal);
          }
          double vramGb = 0.0;
          if (vramMb != null) {
            vramGb = _mbToGb(vramMb);
          } else if (_specs['vram'] != null && _specs['vram']! > 0) {
            vramGb = _specs['vram']!;
          }
          if (vramGb > maxVramGb) maxVramGb = vramGb;

          // Optional TDP field (tp) – may be number or string, max power in watts
          var tpVal = gpu['tp'];
          double? powerVal;
          if (tpVal is num) {
            powerVal = tpVal.toDouble();
          } else if (tpVal is String) {
            powerVal = double.tryParse(tpVal);
          }
          double powerW = 0.0;
          if (powerVal != null) {
            powerW = powerVal;
          } else if (_specs['power'] != null && _specs['power']! > 0) {
            powerW = _specs['power']!;
          }
          if (powerW > maxPowerW) maxPowerW = powerW;
        }
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GPU',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          // GPU Utilization chart (if we have history)
          if (_gpuUtilSpots.isNotEmpty) ...[
            Text(
              'GPU Utilization',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            _buildMiniChart(
              _gpuUtilSpots,
              Colors.blue,
              isPercent: true,
              height: 150,
              loading: _chartLoading,
              chartTime: _chartTime,
            ),
            const SizedBox(height: 24),
          ],
          // GPU VRAM usage chart (if we have history)
          if (_gpuVramSpots.isNotEmpty) ...[
            Text(
              'GPU VRAM Usage',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            _buildMiniChart(
              _gpuVramSpots,
              Colors.purple,
              isPercent: false,
              height: 150,
              maxY: maxVramGb > 0 ? maxVramGb : null,
              loading: _chartLoading,
              chartTime: _chartTime,
            ),
            const SizedBox(height: 24),
          ],
          // GPU Power draw chart (if we have history)
          if (_gpuPowerSpots.isNotEmpty) ...[
            Text(
              'GPU Power Draw',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            _buildMiniChart(
              _gpuPowerSpots,
              Colors.green,
              isPercent: false,
              height: 150,
              maxY: maxPowerW > 0 ? maxPowerW : null,
              loading: _chartLoading,
              chartTime: _chartTime,
            ),
            const SizedBox(height: 24),
          ],
          // Summary stats (total power)
          _buildStatsGrid([
            _StatItem('Power', '${totalPower.toStringAsFixed(2)} W'),
          ]),
          const SizedBox(height: 24),
          // Detailed GPU cards
          if (gpus != null && gpus.isNotEmpty) ...[
            Text('GPUs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...gpus.entries.map((e) {
              final gpu = e.value;
              if (gpu is Map) {
                final name = gpu['n']?.toString() ?? 'GPU ${e.key}';
                final utilisation = gpu['u'] is num
                    ? (gpu['u'] as num).toDouble()
                    : null;
                final power = gpu['p'] is num
                    ? (gpu['p'] as num).toDouble()
                    : null;
                final vramUsedMb = gpu['mu'] is num
                    ? (gpu['mu'] as num).toDouble()
                    : null;
                final vramTotalMb = gpu['mt'] is num
                    ? (gpu['mt'] as num).toDouble()
                    : null;
                // Fallback specs based on model name
                final _specs = _gpuSpecs(name);
                final fallbackTotal =
                    _specs['vram'] != null && _specs['vram']! > 0
                    ? _specs['vram']! * 1024 * 1024 * 1024
                    : null;
                final totalVram = vramTotalMb != null
                    ? vramTotalMb * 1024 * 1024
                    : fallbackTotal;
                return Card(
                  child: ListTile(
                    title: Text(name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (utilisation != null)
                          Text(
                            'Utilization: ${utilisation.toStringAsFixed(1)}%',
                          ),
                        if (vramUsedMb != null && totalVram != null)
                          Text(
                            'VRAM: ${_formatBytes(vramUsedMb * 1024 * 1024)} / ${_formatBytes(totalVram)}',
                          ),
                      ],
                    ),
                    trailing: power != null
                        ? Text('${power.toStringAsFixed(2)} W')
                        : null,
                  ),
                );
              }
              return const SizedBox.shrink();
            }).toList(),
          ] else
            const Center(child: Text('No GPU data available.')),
        ],
      ),
    );
  }
}

class _StatItem {
  final String label;
  final String value;
  _StatItem(this.label, this.value);
}

class _ChartTimeOption {
  final String key;
  final String type;
  final Duration duration;

  const _ChartTimeOption(this.key, this.type, this.duration);

  String get label {
    switch (key) {
      case '1m':
        return '1 minute';
      case '1h':
        return '1 hour';
      case '1d':
        return '1 day';
      case '1w':
        return '1 week';
      case '1M':
        return '1 month';
      default:
        return key;
    }
  }
}
