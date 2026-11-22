import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:transit_card_analyzer/app/app_dependencies.dart';
import 'package:transit_card_analyzer/app/harmony_app.dart';
import 'package:transit_card_analyzer/app/harmony_gallery_controller.dart';
import 'package:transit_card_analyzer/features/qr/data/harmony_qr_scanner.dart';
import 'package:transit_card_analyzer/features/qr/presentation/qr_page.dart';
import 'package:transit_card_analyzer/features/qr/presentation/qr_scan_page.dart';
import 'package:transit_card_analyzer/features/updates/update_service.dart';
import 'package:transit_card_analyzer/gallery/gallery_app.dart';
import 'package:transit_card_analyzer/gallery/gallery_controller.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_models.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_service.dart';
import 'package:transit_card_analyzer/platform/qr/qr_image_picker.dart';
import 'package:transit_card_analyzer/platform/storage/settings_store.dart';

import 'support/test_database.dart';
import 'support/gallery_scroll.dart';

void main() {
  testWidgets('已有鸿蒙控制器时首帧直达首页，不闪过 DEBUG 加载页', (tester) async {
    final app = AppDependencies(
      settingsStore: MemorySettingsStore(),
      bundle: MissingTestAssets(),
      database: testDatabase(),
      channel: _TagChannel(),
    );
    final controller = HarmonyGalleryController(app);
    addTearDown(app.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(GalleryApp(controller: controller));

    expect(find.text('开始读取'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.debugShowCheckedModeBanner, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鸿蒙同意后直达原版 2.x，不加载样例，也不自动读卡', (tester) async {
    final channel = _TagChannel();
    final database = testDatabase();
    await tester.pumpWidget(
      HarmonyApp(
        settingsStore: MemorySettingsStore(),
        createDependencies: (store) => AppDependencies(
          settingsStore: store,
          bundle: MissingTestAssets(),
          database: database,
          channel: channel,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GalleryApp), findsNothing);
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    final gallery = tester.widget<GalleryApp>(find.byType(GalleryApp));
    final controller = gallery.controller!;
    expect(controller.isLive, isTrue);
    expect(controller.savedCards, isEmpty);
    expect(find.text('开始读取'), findsOneWidget);
    expect(find.text('模拟数据'), findsNothing);
    expect(channel.starts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鸿蒙专家页使用安卓 2.x 的读取信息结构', (tester) async {
    final channel = _TagChannel();
    final app = AppDependencies(
      settingsStore: MemorySettingsStore(),
      bundle: MissingTestAssets(),
      database: testDatabase(),
      channel: channel,
    );
    await tester.runAsync(app.init);
    final controller = HarmonyGalleryController(app)..initialize();
    addTearDown(app.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(GalleryApp(controller: controller));
    await tester.runAsync(() async {
      controller.read();
      await channel.waitForStart();
      channel.deliver(channel.starts.single);
      for (var attempt = 0; attempt < 100 && !controller.hasRead; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.hasRead, isTrue);

    await tester.tap(find.byKey(const ValueKey('nav-expert')));
    await tester.pumpAndSettle();
    expect(find.text('信息获取'), findsOneWidget);
    expect(find.text('交通数据解析'), findsOneWidget);
    expect(find.text('APDU / Raw Data'), findsOneWidget);
    expect(find.text('JT/T 978 符合性'), findsNothing);
    expect(find.text('卡片识别'), findsOneWidget);
    expect(find.text('识别状态'), findsOneWidget);
    expect(find.text('NFC-F 系统码'), findsNothing);

    await tester.tap(find.text('交通数据解析'));
    await tester.pumpAndSettle();
    expect(find.text('交通应用信息'), findsOneWidget);
    expect(find.text('余额语义'), findsOneWidget);
    expect(find.text('剩余有效天数'), findsOneWidget);

    await tester.tap(find.text('APDU / Raw Data'));
    await tester.pumpAndSettle();
    expect(find.text('APDU 命令 / 响应（0 项）'), findsOneWidget);
    expect(find.text('0x1A / 0x1E 原始记录（0 条）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鸿蒙设置打开真实知识库，显示本地 TU 和 CU 参考数据', (tester) async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    final directory = Directory.systemTemp.createTempSync(
      'trafarch-knowledge-',
    );
    messenger.setMockMethodCallHandler(paths, (call) async => directory.path);
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      directory.deleteSync(recursive: true);
    });
    final store = MemorySettingsStore({SettingsKeys.legalConsent: 'true'});
    final app = AppDependencies(
      settingsStore: store,
      database: testDatabase(),
      channel: _TagChannel(),
    );
    addTearDown(() {
      if (!app.disposed) app.dispose();
    });
    await tester.runAsync(app.init);
    expect(app.knowledgeBase?.packageVersions.keys, containsAll(['TU', 'CU']));
    expect(
      app.knowledgeBase?.coverageDatasets.map((dataset) => dataset.system),
      containsAll(['tu', 'cu']),
    );

    await tester.pumpWidget(
      HarmonyApp(settingsStore: store, createDependencies: (_) => app),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('TU 41 个地区 / CU 7 个地区'), findsNothing);
    expect(find.text('已存在的记录'), findsOneWidget);
    expect(find.text('上海交通卡可透支余额'), findsOneWidget);
    expect(find.text('导出卡片记录'), findsOneWidget);
    expect(find.text('导入卡片记录'), findsOneWidget);

    await tester.tap(find.text('已存在的记录'));
    await tester.pumpAndSettle();
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('覆盖'), findsOneWidget);
    expect(find.text('每次询问'), findsOneWidget);
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(app.archiveConflictPolicy.name, 'skip');

    await tester.tap(find.text('上海交通卡可透支余额'));
    await tester.pumpAndSettle();
    expect(app.includeShanghaiOverdraft, isTrue);

    await tester.tap(find.text('知识库'));
    await tester.pump();
    for (var attempt = 0; attempt < 200; attempt++) {
      if (find
              .byKey(const ValueKey('knowledge-search-entry'))
              .evaluate()
              .isNotEmpty ||
          find.text('本地参考数据暂不可用').evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('knowledge-search-entry')),
      findsOneWidget,
    );
    expect(find.text('数据概况'), findsOneWidget);
    expect(find.text('交通联合 TU'), findsOneWidget);
    await tester.tap(find.text('城市一卡通 CU'));
    await tester.pumpAndSettle();
    expect(find.text('城市一卡通参考数据'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('读取后自动保存'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('记录运行日志'),
      250,
      scrollable: galleryVerticalScroll(),
    );
    await tester.pumpAndSettle();
    expect(find.text('诊断日志'), findsOneWidget);
    await tester.tap(find.text('记录运行日志'));
    await tester.pumpAndSettle();
    expect(app.loggingEnabled, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鸿蒙启动只提示一次更新，设置内可手动检查', (tester) async {
    var calls = 0;
    final updates = UpdateService(
      currentBuild: 1,
      manifestUrl: 'https://example.com/manifest.json',
      fetch: (_, _) async => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format_version': 1,
            'app': {
              'build': ++calls == 1 ? 2 : 1,
              'version': '2.0.0',
              'notes': '更新说明',
              'download_url': 'https://example.com/app.hap',
            },
          }),
        ),
      ),
    );
    final store = MemorySettingsStore({SettingsKeys.legalConsent: 'true'});
    await tester.pumpWidget(
      HarmonyApp(
        settingsStore: store,
        createDependencies: (store) => AppDependencies(
          settingsStore: store,
          bundle: MissingTestAssets(),
          database: testDatabase(),
          channel: _TagChannel(),
          updateService: updates,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 2.0.0'), findsOneWidget);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    final check = find.text('检查更新');
    await tester.scrollUntilVisible(
      check,
      250,
      scrollable: galleryVerticalScroll(),
    );
    await tester.ensureVisible(check);
    await tester.pumpAndSettle();
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(find.text('暂无更新'), findsOneWidget);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧的系统扫码偏好不再生效，应用内相机和相册仍可用', (tester) async {
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = HarmonyQrScanner();
    addTearDown(() => MobileScannerPlatform.instance = previous);
    final messenger = tester.binding.defaultBinaryMessenger;
    var starts = 0;
    var picks = 0;
    messenger.setMockMethodCallHandler(HarmonyQrScanner.channel, (call) async {
      if (call.method == 'stop') return null;
      expect(call.method, 'start');
      starts++;
      throw PlatformException(
        code: 'permission_denied',
        message: '请在系统设置中允许 TrafArch 使用相机',
      );
    });
    messenger.setMockMethodCallHandler(qrImagePickerChannel, (call) async {
      expect(call.method, 'pickImage');
      picks++;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(HarmonyQrScanner.channel, null);
      messenger.setMockMethodCallHandler(qrImagePickerChannel, null);
    });
    await tester.pumpWidget(
      HarmonyApp(
        settingsStore: MemorySettingsStore({'scan_kit_enabled': 'true'}),
        createDependencies: (store) => AppDependencies(
          settingsStore: store,
          bundle: MissingTestAssets(),
          database: testDatabase(),
          channel: _TagChannel(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('读取后自动保存'), findsOneWidget);
    expect(find.textContaining('系统扫码'), findsNothing);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('扫码'));
    await tester.pumpAndSettle();
    expect(find.byType(QrPage), findsOneWidget);
    expect(find.textContaining('内置二维码样例'), findsNothing);
    await tester.tap(find.text('扫描二维码'));
    await tester.pumpAndSettle();
    expect(find.byType(QrScanPage), findsOneWidget);
    expect(find.textContaining('请在系统设置中允许 TrafArch 使用相机'), findsOneWidget);
    expect(starts, 1);
    await tester.tap(find.text('重试相机'));
    await tester.pumpAndSettle();
    expect(starts, 2);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册导入'));
    await tester.pumpAndSettle();
    expect(picks, 1);
    expect(find.textContaining('尚未获取二维码'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '扫描二维码'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('开始读取'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('2.x 实时会话使用原版发现与关闭，取消后不接纳旧结果', () async {
    final channel = _TagChannel();
    final app = AppDependencies(
      settingsStore: MemorySettingsStore(),
      bundle: MissingTestAssets(),
      database: testDatabase(),
      channel: channel,
    );
    final gallery = HarmonyGalleryController(app)..initialize();
    addTearDown(app.dispose);
    addTearDown(gallery.dispose);
    await app.init();
    gallery.read();
    await channel.waitForStart();
    final stale = channel.starts.single;
    gallery.cancelRead();
    channel.deliver(stale);
    await Future<void>.delayed(Duration.zero);
    expect(gallery.readState, GalleryReadState.unread);
    expect(gallery.readMetadata, isEmpty);

    gallery.read();
    await channel.waitForStart(count: 2);
    final active = channel.starts.last;
    channel.deliver(active);
    for (var attempt = 0; attempt < 100 && !gallery.hasRead; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(gallery.readState, GalleryReadState.success);
    expect(gallery.readMetadata['连接类型'], 'NfcA');
    expect(gallery.canSaveCurrent, isFalse);
    expect(channel.stops, containsAllInOrder([stale, active]));
  });
}

class _TagChannel implements SessionNfcChannel {
  final starts = <String>[];
  final stops = <String>[];
  final _replies = <String, Completer<NfcScanResult?>>{};

  Future<void> waitForStart({int count = 1}) async {
    for (var attempt = 0; attempt < 100 && starts.length < count; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(starts, hasLength(count));
  }

  void deliver(String sessionId) {
    _replies
        .remove(sessionId)!
        .complete(
          NfcScanResult(
            sessionId: sessionId,
            uid: '00 11',
            technologies: const ['NfcA'],
            isoDepConnected: false,
            timestamp: DateTime(2026, 11, 20, 19, 45),
          ),
        );
  }

  @override
  Future<NfcScanResult?> scanSession(String sessionId) {
    starts.add(sessionId);
    final reply = _replies[sessionId] = Completer<NfcScanResult?>();
    return reply.future;
  }

  @override
  Future<void> closeSession(String sessionId) async => stops.add(sessionId);

  @override
  Future<List<int>> exchangeSession(String sessionId, List<int> apdu) =>
      throw StateError('Metadata-only tag must not receive an APDU.');

  @override
  Future<NfcScanResult?> scanOnce() => throw UnimplementedError();

  @override
  Future<void> stopScan() => throw UnimplementedError();

  @override
  Future<List<int>> transceive(List<int> apdu) => throw UnimplementedError();
}
