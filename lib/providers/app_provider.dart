import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppProvider extends ChangeNotifier {
  final SharedPreferences _prefs;
  ThemeMode _themeMode;
  Locale _locale = const Locale('en');
  int _refreshIntervalSeconds;

  AppProvider(this._prefs)
    : _themeMode = _prefs.getBool('isDark') == true
          ? ThemeMode.dark
          : ThemeMode.light,
      _isDetailed = _prefs.getBool('isDetailed') ?? false,
      _refreshIntervalSeconds = _prefs.getInt('refreshIntervalSeconds') ?? 1;

  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;

  bool _isDetailed;
  bool get isDetailed => _isDetailed;

  int get refreshIntervalSeconds => _refreshIntervalSeconds;

  void toggleTheme(bool isDark) {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    _prefs.setBool('isDark', isDark);
    notifyListeners();
  }

  void setDetailedMode(bool isDetailed) {
    _isDetailed = isDetailed;
    _prefs.setBool('isDetailed', isDetailed);
    notifyListeners();
  }

  void setRefreshIntervalSeconds(int seconds) {
    _refreshIntervalSeconds = seconds;
    _prefs.setInt('refreshIntervalSeconds', seconds);
    notifyListeners();
  }

  void setLocale(Locale locale) {
    _locale = locale;
    notifyListeners();
  }
}
