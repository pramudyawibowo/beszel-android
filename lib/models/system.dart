import 'package:pocketbase/pocketbase.dart';

class System {
  final String id;
  final String name;
  final String host;
  final String status;
  final double cpuPercent;
  final double memoryPercent;
  final double diskPercent;
  final double? gpuPercent;
  final String updated;
  final String? os;
  final Map<String, dynamic> info;

  System({
    required this.id,
    required this.name,
    required this.host,
    required this.status,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskPercent,
    this.gpuPercent,
    required this.updated,
    this.os,
    required this.info,
  });

  factory System.fromRecord(RecordModel record) {
    // Helper to safely parse double
    double toDouble(dynamic val) {
      if (val is int) return val.toDouble();
      if (val is double) return val;
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    double? toDoubleOrNull(dynamic val) {
      if (val is int) return val.toDouble();
      if (val is double) return val;
      if (val is String) return double.tryParse(val);
      return null;
    }

    final info = record.data['info'] is Map
        ? record.data['info'] as Map<String, dynamic>
        : <String, dynamic>{};

    return System(
      id: record.id,
      name: record.getStringValue('name'),
      host: record.getStringValue('host'),
      status: record.getStringValue('status'),
      cpuPercent: toDouble(info['cpu']),
      memoryPercent: toDouble(info['mp']),
      diskPercent: toDouble(info['dp']),
      gpuPercent: toDoubleOrNull(info['g']),
      updated: record.get<String>('updated'),
      os: info['k'] as String?,
      info: info,
    );
  }
}
