enum AppThemeMode { system, light, dark }

class AppSettings {
  AppThemeMode themeMode;
  int accentColor;

  /// 界面风格：default / fluent / antd。
  String uiStyle;

  double terminalFontSize;
  String terminalFontFamily;
  String terminalTheme;
  int scrollback;
  bool copyOnSelect;
  bool rightClickPaste;
  String cursorStyle;
  bool terminalColorHelper;

  int monitorIntervalSeconds;
  String downloadDir;
  bool sftpFollowTerminal;
  bool sftpShowHidden;
  bool confirmOnCloseTab;

  String backupKey;
  bool rememberBackupKey;

  String gdriveClientId;
  String gdriveClientSecret;
  String gdriveCredentials;
  String gdriveAccountHint;
  bool gdriveAutoUpload;
  int gdriveAutoUploadHours;
  bool gdriveUploadOnChange;
  bool gdriveAutoImport;
  int gdriveKeepCount;
  int lastUploadAt;
  String lastImportedRemoteId;
  int lastImportedRemoteTime;

  AppSettings({
    this.themeMode = AppThemeMode.system,
    this.accentColor = 0xFF007AFF,
    this.uiStyle = 'default',
    this.terminalFontSize = 14,
    this.terminalFontFamily = '',
    this.terminalTheme = 'FinalShell 暗色',
    this.scrollback = 5000,
    this.copyOnSelect = true,
    this.rightClickPaste = true,
    this.cursorStyle = 'block',
    this.terminalColorHelper = true,
    this.monitorIntervalSeconds = 2,
    this.downloadDir = '',
    this.sftpFollowTerminal = false,
    this.sftpShowHidden = false,
    this.confirmOnCloseTab = true,
    this.backupKey = '',
    this.rememberBackupKey = true,
    this.gdriveClientId = '',
    this.gdriveClientSecret = '',
    this.gdriveCredentials = '',
    this.gdriveAccountHint = '',
    this.gdriveAutoUpload = false,
    this.gdriveAutoUploadHours = 24,
    this.gdriveUploadOnChange = false,
    this.gdriveAutoImport = false,
    this.gdriveKeepCount = 10,
    this.lastUploadAt = 0,
    this.lastImportedRemoteId = '',
    this.lastImportedRemoteTime = 0,
  });

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accentColor': accentColor,
        'uiStyle': uiStyle,
        'terminalFontSize': terminalFontSize,
        'terminalFontFamily': terminalFontFamily,
        'terminalTheme': terminalTheme,
        'scrollback': scrollback,
        'copyOnSelect': copyOnSelect,
        'rightClickPaste': rightClickPaste,
        'cursorStyle': cursorStyle,
        'terminalColorHelper': terminalColorHelper,
        'monitorIntervalSeconds': monitorIntervalSeconds,
        'downloadDir': downloadDir,
        'sftpFollowTerminal': sftpFollowTerminal,
        'sftpShowHidden': sftpShowHidden,
        'confirmOnCloseTab': confirmOnCloseTab,
        'backupKey': rememberBackupKey ? backupKey : '',
        'rememberBackupKey': rememberBackupKey,
        'gdriveClientId': gdriveClientId,
        'gdriveClientSecret': gdriveClientSecret,
        'gdriveCredentials': gdriveCredentials,
        'gdriveAccountHint': gdriveAccountHint,
        'gdriveAutoUpload': gdriveAutoUpload,
        'gdriveAutoUploadHours': gdriveAutoUploadHours,
        'gdriveUploadOnChange': gdriveUploadOnChange,
        'gdriveAutoImport': gdriveAutoImport,
        'gdriveKeepCount': gdriveKeepCount,
        'lastUploadAt': lastUploadAt,
        'lastImportedRemoteId': lastImportedRemoteId,
        'lastImportedRemoteTime': lastImportedRemoteTime,
      };

  /// 备份里只携带与具体设备无关的偏好设置，不包含云盘凭据和加密密钥。
  Map<String, dynamic> toPortableJson() => {
        'themeMode': themeMode.name,
        'accentColor': accentColor,
        'uiStyle': uiStyle,
        'terminalFontSize': terminalFontSize,
        'terminalFontFamily': terminalFontFamily,
        'terminalTheme': terminalTheme,
        'scrollback': scrollback,
        'copyOnSelect': copyOnSelect,
        'rightClickPaste': rightClickPaste,
        'cursorStyle': cursorStyle,
        'terminalColorHelper': terminalColorHelper,
        'monitorIntervalSeconds': monitorIntervalSeconds,
        'sftpFollowTerminal': sftpFollowTerminal,
        'sftpShowHidden': sftpShowHidden,
        'confirmOnCloseTab': confirmOnCloseTab,
      };

  void applyPortable(Map<String, dynamic> j) {
    final s = AppSettings.fromJson({...toJson(), ...j});
    themeMode = s.themeMode;
    accentColor = s.accentColor;
    uiStyle = s.uiStyle;
    terminalFontSize = s.terminalFontSize;
    terminalFontFamily = s.terminalFontFamily;
    terminalTheme = s.terminalTheme;
    scrollback = s.scrollback;
    copyOnSelect = s.copyOnSelect;
    rightClickPaste = s.rightClickPaste;
    cursorStyle = s.cursorStyle;
    terminalColorHelper = s.terminalColorHelper;
    monitorIntervalSeconds = s.monitorIntervalSeconds;
    sftpFollowTerminal = s.sftpFollowTerminal;
    sftpShowHidden = s.sftpShowHidden;
    confirmOnCloseTab = s.confirmOnCloseTab;
  }

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        themeMode: AppThemeMode.values.firstWhere(
            (e) => e.name == j['themeMode'],
            orElse: () => AppThemeMode.system),
        accentColor: j['accentColor'] as int? ?? 0xFF007AFF,
        uiStyle: j['uiStyle'] as String? ?? 'default',
        terminalFontSize: (j['terminalFontSize'] as num?)?.toDouble() ?? 14,
        terminalFontFamily: j['terminalFontFamily'] as String? ?? '',
        terminalTheme: j['terminalTheme'] as String? ?? 'FinalShell 暗色',
        scrollback: j['scrollback'] as int? ?? 5000,
        copyOnSelect: j['copyOnSelect'] as bool? ?? true,
        rightClickPaste: j['rightClickPaste'] as bool? ?? true,
        cursorStyle: j['cursorStyle'] as String? ?? 'block',
        terminalColorHelper: j['terminalColorHelper'] as bool? ?? true,
        monitorIntervalSeconds: j['monitorIntervalSeconds'] as int? ?? 2,
        downloadDir: j['downloadDir'] as String? ?? '',
        sftpFollowTerminal: j['sftpFollowTerminal'] as bool? ?? false,
        sftpShowHidden: j['sftpShowHidden'] as bool? ?? false,
        confirmOnCloseTab: j['confirmOnCloseTab'] as bool? ?? true,
        backupKey: j['backupKey'] as String? ?? '',
        rememberBackupKey: j['rememberBackupKey'] as bool? ?? true,
        gdriveClientId: j['gdriveClientId'] as String? ?? '',
        gdriveClientSecret: j['gdriveClientSecret'] as String? ?? '',
        gdriveCredentials: j['gdriveCredentials'] as String? ?? '',
        gdriveAccountHint: j['gdriveAccountHint'] as String? ?? '',
        gdriveAutoUpload: j['gdriveAutoUpload'] as bool? ?? false,
        gdriveAutoUploadHours: j['gdriveAutoUploadHours'] as int? ?? 24,
        gdriveUploadOnChange: j['gdriveUploadOnChange'] as bool? ?? false,
        gdriveAutoImport: j['gdriveAutoImport'] as bool? ?? false,
        gdriveKeepCount: j['gdriveKeepCount'] as int? ?? 10,
        lastUploadAt: j['lastUploadAt'] as int? ?? 0,
        lastImportedRemoteId: j['lastImportedRemoteId'] as String? ?? '',
        lastImportedRemoteTime: j['lastImportedRemoteTime'] as int? ?? 0,
      );
}
