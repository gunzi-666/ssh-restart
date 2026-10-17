import 'package:flutter/foundation.dart';

import '../models/session_config.dart';

enum TabStatus { connecting, connected, disconnected, error }

abstract class AppTab extends ChangeNotifier {
  AppTab(this.config) : id = newId();

  final String id;
  SessionConfig config;
  TabStatus status = TabStatus.connecting;
  String? errorMessage;

  String get title => config.displayName;

  Future<void> connect();
  Future<void> reconnect() => connect();
  Future<void> close();

  bool _disposed = false;
  bool get isDisposed => _disposed;

  void setStatus(TabStatus s, [String? err]) {
    status = s;
    errorMessage = err;
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
