import 'dart:convert';

import 'package:beszel_pro/models/system.dart';
import 'package:beszel_pro/services/pocketbase_service.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Halaman detail sistem yang bisa menampilkan seluruh metadata,
/// atau satu section tertentu seperti `containers` dan `systemd`.
class SystemDetailsScreen extends StatefulWidget {
  final System system;
  final String? sectionKey;
  final String? sectionTitle;

  const SystemDetailsScreen({
    super.key,
    required this.system,
    this.sectionKey,
    this.sectionTitle,
  });

  @override
  State<SystemDetailsScreen> createState() => _SystemDetailsScreenState();
}

class _SystemDetailsScreenState extends State<SystemDetailsScreen> {
  Map<String, dynamic>? _systemDetails;
  bool _isLoading = true;
  String? _error;

  static const Map<String, String> _labelMap = {
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
  };

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
      if (!mounted) return;
      setState(() {
        _systemDetails = details;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  dynamic _resolveData() {
    final details = _systemDetails;
    if (details == null) return null;

    final key = widget.sectionKey;
    if (key == null || key.isEmpty) {
      return details;
    }

    final directValue = details[key];
    if (directValue != null) {
      return directValue;
    }

    if (key == 'systemd') {
      return details['services'] ?? details['systemd'];
    }

    if (key == 'containers') {
      return details['containers'];
    }

    return null;
  }

  String _titleForSection() {
    if (widget.sectionTitle != null && widget.sectionTitle!.isNotEmpty) {
      return widget.sectionTitle!;
    }

    final key = widget.sectionKey;
    if (key == null || key.isEmpty) {
      return '${widget.system.name} ${tr('details')}'.trim();
    }

    final prettyKey = key[0].toUpperCase() + key.substring(1);
    return '${widget.system.name} $prettyKey'.trim();
  }

  String _friendlyLabel(String key) {
    return _labelMap[key] ?? key;
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
            child: SelectableText(value),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimitiveValue(dynamic value) {
    return SelectableText(value?.toString() ?? '-');
  }

  Widget _buildStructuredValue(dynamic value) {
    if (value == null) {
      return const Text('-');
    }

    if (value is String) {
      final trimmed = value.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return _buildStructuredValue(jsonDecode(value));
        } catch (_) {}
      }
      return _buildPrimitiveValue(value);
    }

    if (value is Map) {
      final entries = value.entries.toList();
      if (entries.isEmpty) {
        return const Text('-');
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entries.map((entry) {
          final entryValue = entry.value;
          if (entryValue is Map || entryValue is List) {
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ExpansionTile(
                title: Text(entry.key.toString()),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: _buildStructuredValue(entryValue),
                  ),
                ],
              ),
            );
          }

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: _buildRow(
              entry.key.toString(),
              entryValue?.toString() ?? '-',
            ),
          );
        }).toList(),
      );
    }

    if (value is List) {
      if (value.isEmpty) {
        return const Text('-');
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(value.length, (index) {
          final item = value[index];
          if (item is Map || item is List) {
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${index + 1}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _buildStructuredValue(item),
                  ],
                ),
              ),
            );
          }

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: _buildRow('#${index + 1}', item?.toString() ?? '-'),
          );
        }),
      );
    }

    return _buildPrimitiveValue(value);
  }

  Widget _buildFullDetails(Map<String, dynamic> data) {
    final filtered = data.entries.where(
      (e) =>
          e.key != 'id' &&
          e.key != 'collectionId' &&
          e.key != 'collectionName' &&
          e.key != 'system',
    );

    if (filtered.isEmpty) {
      return Center(child: Text(tr('no_data_available')));
    }

    final orderedKeys = <String>[
      ..._labelMap.keys.where((key) => data.containsKey(key)),
      ...filtered.map((e) => e.key).where((key) => !_labelMap.containsKey(key)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: orderedKeys.map((key) {
        final value = data[key];
        if (value is Map || value is List) {
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ExpansionTile(
              title: Text(_friendlyLabel(key)),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _buildStructuredValue(value),
                ),
              ],
            ),
          );
        }

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: _buildRow(
            _friendlyLabel(key),
            value?.toString() ?? '-',
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBody(dynamic data) {
    if (data == null) {
      return Center(child: Text(tr('no_data_available')));
    }

    if (data is Map<String, dynamic>) {
      if (widget.sectionKey == null || widget.sectionKey!.isEmpty) {
        return _buildFullDetails(data);
      }

      return _buildStructuredValue(data);
    }

    return _buildStructuredValue(data);
  }

  @override
  Widget build(BuildContext context) {
    final data = _resolveData();

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleForSection()),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildBody(data),
            ),
    );
  }
}
