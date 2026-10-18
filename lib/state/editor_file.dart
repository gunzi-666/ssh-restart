import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart';

import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';

import '../services/ssh/sftp_service.dart';

/// 根据文件名/扩展名推断高亮语言（返回 re_highlight 的语言名与 Mode）。
({String name, Mode mode})? detectLanguage(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower == 'dockerfile') return (name: 'dockerfile', mode: langDockerfile);
  if (lower == 'makefile') return (name: 'makefile', mode: langMakefile);
  if (lower.endsWith('.bashrc') ||
      lower.endsWith('.zshrc') ||
      lower.endsWith('.profile')) {
    return (name: 'bash', mode: langBash);
  }
  final dot = lower.lastIndexOf('.');
  if (dot < 0) return null;
  switch (lower.substring(dot + 1)) {
    case 'sh':
    case 'bash':
    case 'zsh':
      return (name: 'bash', mode: langBash);
    case 'py':
      return (name: 'python', mode: langPython);
    case 'js':
    case 'mjs':
    case 'cjs':
      return (name: 'javascript', mode: langJavascript);
    case 'ts':
      return (name: 'typescript', mode: langTypescript);
    case 'json':
      return (name: 'json', mode: langJson);
    case 'yaml':
    case 'yml':
      return (name: 'yaml', mode: langYaml);
    case 'dart':
      return (name: 'dart', mode: langDart);
    case 'sql':
      return (name: 'sql', mode: langSql);
    case 'go':
      return (name: 'go', mode: langGo);
    case 'rs':
      return (name: 'rust', mode: langRust);
    case 'java':
      return (name: 'java', mode: langJava);
    case 'kt':
    case 'kts':
      return (name: 'kotlin', mode: langKotlin);
    case 'c':
    case 'h':
      return (name: 'c', mode: langC);
    case 'cpp':
    case 'cc':
    case 'cxx':
    case 'hpp':
      return (name: 'cpp', mode: langCpp);
    case 'cs':
      return (name: 'csharp', mode: langCsharp);
    case 'php':
      return (name: 'php', mode: langPhp);
    case 'rb':
      return (name: 'ruby', mode: langRuby);
    case 'swift':
      return (name: 'swift', mode: langSwift);
    case 'lua':
      return (name: 'lua', mode: langLua);
    case 'css':
    case 'scss':
    case 'less':
      return (name: 'css', mode: langCss);
    case 'html':
    case 'htm':
    case 'xml':
    case 'vue':
      return (name: 'xml', mode: langXml);
    case 'md':
    case 'markdown':
      return (name: 'markdown', mode: langMarkdown);
    case 'ini':
    case 'cfg':
    case 'toml':
      return (name: 'ini', mode: langIni);
    case 'conf':
      return (name: 'nginx', mode: langNginx);
    case 'properties':
    case 'env':
      return (name: 'properties', mode: langProperties);
    case 'ps1':
    case 'psm1':
      return (name: 'powershell', mode: langPowershell);
    default:
      return null;
  }
}

/// 一个已在某个 SSH 会话内打开的远程文件（会话内的编辑副标签）。
class EditorFile extends ChangeNotifier {
  EditorFile({required this.sftp, required this.path})
      : name = path.split('/').last {
    // 内容变化时转发通知，用于更新脏标记与保存按钮。
    controller.addListener(_onControllerChanged);
  }

  /// re_editor 的 CodeEditor 会在自身 initState（构建阶段）触发一次控制器通知，
  /// 此时直接 notifyListeners 会导致 "setState called during build"，故在构建阶段
  /// 延迟到帧后再通知。
  void _onControllerChanged() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  bool _disposed = false;

  final SftpService sftp;
  final String path;
  final String name;

  final CodeLineEditingController controller = CodeLineEditingController();
  final CodeScrollController scroll = CodeScrollController();

  String _original = '';
  bool loading = true;
  bool saving = false;
  String? error;

  /// 行书签（0 基行号集合）。
  final Set<int> bookmarks = <int>{};

  bool get dirty => !loading && controller.text != _original;

  ({String name, Mode mode})? get language => detectLanguage(name);

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final text = await sftp.readText(path);
      controller.text = text;
      _original = text;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  /// 保存回服务器，返回错误信息（成功为 null）。
  Future<String?> save() async {
    saving = true;
    notifyListeners();
    String? err;
    try {
      await sftp.writeText(path, controller.text);
      _original = controller.text;
    } catch (e) {
      err = '$e';
    }
    saving = false;
    notifyListeners();
    return err;
  }

  void toggleBookmark(int line) {
    if (!bookmarks.remove(line)) bookmarks.add(line);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_onControllerChanged);
    controller.dispose();
    scroll.dispose();
    super.dispose();
  }
}
