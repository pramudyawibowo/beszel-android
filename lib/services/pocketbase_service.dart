import 'dart:async';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PocketBaseService {
  static final PocketBaseService _instance = PocketBaseService._internal();

  factory PocketBaseService() {
    return _instance;
  }

  PocketBaseService._internal();

  PocketBase? _pb;

  /// Returns the PocketBase instance. Throws if not connected.
  PocketBase get pb {
    if (_pb == null) {
      throw Exception("PocketBase not initialized. Call connect() first.");
    }
    return _pb!;
  }

  /// Checks if PocketBase is initialized
  bool get isInitialized => _pb != null;

  /// Connects to the PocketBase instance at [url] and initializes the AuthStore.
  Future<void> connect(String url) async {
    final prefs = await SharedPreferences.getInstance();

    final store = AsyncAuthStore(
      save: (String data) async => await prefs.setString('pb_auth', data),
      initial: prefs.getString('pb_auth'),
      clear: () async => await prefs.remove('pb_auth'),
    );

    _pb = PocketBase(url, authStore: store);
  }

  /// Fetch system details from the 'system_details' collection.
  /// Returns a map of the record fields or null if not found.
  Future<Map<String, dynamic>?> fetchSystemDetails(String systemId) async {
    final pb = this.pb;
    // Query the system_details collection for the record belonging to the given system.
    final result = await pb
        .collection('system_details')
        .getList(page: 1, perPage: 1, filter: 'id = "$systemId"');
    if (result.items.isNotEmpty) {
      return result.items.first.data;
    }
    return null;
  }
}
