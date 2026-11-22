import 'package:flutter/services.dart';

/// 应用元信息，正式运行时使用鸿蒙安装包的版本信息。
class AppInfo {
  AppInfo._();

  static const _channel = MethodChannel('transit_card_analyzer/app_info');
  static ({String name, int code})? _installedVersion;

  /// 应用英文名称。
  static const String appNameEn = 'TrafArch';

  /// 应用中文名称（暂留空，待正式名称确定后补充）。
  static const String appNameZh = '';

  /// 当前展示用应用名称：中文名留空时回退为英文名。
  static String get appName => appNameZh.isEmpty ? appNameEn : appNameZh;

  static String get version => _installedVersion?.name ?? '开发版';
  static String get buildNumber => (_installedVersion?.code ?? 0).toString();

  static String get displayBuildNumber => buildNumber;

  static const String author = 'kajolno';
  static const String copyright = '© 2026 kajolno';

  static Future<void> loadInstalledVersion() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'getPackageInfo',
      );
      final name = info?['versionName'];
      final code = info?['versionCode'];
      if (name is String && name.trim().isNotEmpty && code is int && code > 0) {
        _installedVersion = (name: name, code: code);
      }
    } on MissingPluginException {
      // Flutter 测试和预览可在没有鸿蒙宿主的环境运行。
    } on PlatformException {
      // 系统版本查询失败时仍可启动应用。
    }
  }
}
