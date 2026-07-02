import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';

/// Halaman terpisah yang menampilkan **detail sistem** lengkap
/// yang disimpan di koleksi `system_details` PocketBase.
class SystemDetailsScreen extends StatefulWidget {
  final System system;

  const SystemDetailsScreen({super.key, required this.system});

  @override
  State<SystemDetailsScreen> createState() => _SystemDetailsScreenState();
}

class _SystemDetailsScreenState extends State<SystemDetailsScreen> {
  Map<String, dynamic>? _systemDetails;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final details = await PocketBaseService().fetchSystemDetails(
        widget.system.id,
      );
      if (mounted) {
        setState(() {
          _systemDetails = details;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(value, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.system.name} ${tr('details')}'.trim()),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : _systemDetails == null
          ? const Center(child: Text('No details found'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: (() {
                  // Mapping raw field names to user‑friendly labels
                  const Map<String, String> labelMap = {
                    'hostname': 'Hostname',
                    'os_name': 'OS',
                    'kernel': 'Kernel',
                    'cpu': 'CPU',
                    'arch': 'Architecture',
                    'cores': 'Cores',
                    'threads': 'Threads',
                    'memory': 'Memory',
                    'updated': 'Updated',
                    'podman': 'Podman',
                    'os': 'OS Code',
                    // add more mappings as needed
                  };
                  // Filter out id and collectionId (and any null values)
                  final entries = _systemDetails!.entries.where(
                    (e) =>
                        e.key != 'id' &&
                        e.key != 'collectionId' &&
                        e.key != 'collectionName' &&
                        e.key != 'system',
                  );
                  // Build rows preserving the order of labelMap keys first, then any others
                  List<Widget> rows = [];
                  // First, add rows for known keys in the order of labelMap
                  for (final key in labelMap.keys) {
                    final entry = entries.firstWhere(
                      (e) => e.key == key,
                      orElse: () => const MapEntry('', null),
                    );
                    if (entry.key.isNotEmpty) {
                      rows.add(
                        _buildRow(
                          labelMap[key] ?? key,
                          entry.value?.toString() ?? '-',
                        ),
                      );
                    }
                  }
                  // Then add any remaining keys that were not in labelMap
                  for (final e in entries) {
                    if (!labelMap.containsKey(e.key)) {
                      rows.add(_buildRow(e.key, e.value?.toString() ?? '-'));
                    }
                  }
                  return rows;
                })(),
              ),
            ),
    );
  }
}
