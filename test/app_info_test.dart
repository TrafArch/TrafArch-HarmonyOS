import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transit_card_analyzer/app/app_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('版本展示使用鸿蒙安装包的版本号和构建号', () async {
    const channel = MethodChannel('transit_card_analyzer/app_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPackageInfo');
      return {'versionName': '1.2.3.4', 'versionCode': 5432};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await AppInfo.loadInstalledVersion();

    expect(AppInfo.version, '1.2.3.4');
    expect(AppInfo.displayBuildNumber, '5432');
  });
}
