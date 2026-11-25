import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transit_card_analyzer/app/app_dependencies.dart';
import 'package:transit_card_analyzer/app/harmony_app.dart';
import 'package:transit_card_analyzer/features/updates/update_service.dart';
import 'package:transit_card_analyzer/gallery/gallery_app.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_models.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_service.dart';
import 'package:transit_card_analyzer/platform/storage/settings_store.dart';

import 'support/gallery_scroll.dart';
import 'support/test_database.dart';

void main() {
  testWidgets('鸿蒙同意后直达实卡 2.x，不加载样例也不自动读卡', (tester) async {
    final channel = _TagChannel();
    await tester.pumpWidget(
      HarmonyApp(
        settingsStore: MemorySettingsStore(),
        createDependencies: (store) => AppDependencies(
          settingsStore: store,
          bundle: MissingTestAssets(),
          database: testDatabase(),
          channel: channel,
          nfcAdapterStates: const Stream.empty(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GalleryApp), findsNothing);
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();

    final gallery = tester.widget<GalleryApp>(find.byType(GalleryApp));
    expect(gallery.liveApp, isNotNull);
    expect(find.text('开始读取'), findsOneWidget);
    expect(find.text('模拟数据'), findsNothing);
    expect(channel.starts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鸿蒙设置与知识库使用完整实卡适配器', (tester) async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    final directory = Directory.systemTemp.createTempSync(
      'trafarch-harmony-knowledge-',
    );
    messenger.setMockMethodCallHandler(paths, (call) async => directory.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // The local knowledge database may still be closing on the test host.
      }
    });
    final store = MemorySettingsStore({SettingsKeys.legalConsent: 'true'});
    final app = AppDependencies(
      settingsStore: store,
      database: testDatabase(),
      channel: _TagChannel(),
      nfcAdapterStates: const Stream.empty(),
    );
    await tester.runAsync(app.init);
    expect(app.knowledgeBase?.packageVersions.keys, containsAll(['TU', 'CU']));

    await tester.pumpWidget(
      HarmonyApp(settingsStore: store, createDependencies: (_) => app),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('已存在的记录'), findsOneWidget);
    expect(find.text('上海交通卡可透支余额'), findsOneWidget);
    expect(find.text('导出卡片记录'), findsOneWidget);
    expect(find.text('导入卡片记录'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('震动'),
      250,
      scrollable: galleryVerticalScroll(),
    );
    await tester.pumpAndSettle();
    expect(find.text('震动'), findsOneWidget);

    await tester.tap(find.text('震动'));
    await tester.pumpAndSettle();
    expect(app.hapticEnabled, isFalse);
    await tester.tap(find.text('震动'));
    await tester.pumpAndSettle();
    expect(app.hapticEnabled, isTrue);

    await tester.scrollUntilVisible(
      find.text('知识库'),
      -250,
      scrollable: galleryVerticalScroll(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识库'));
    await tester.pump();
    for (var attempt = 0; attempt < 200; attempt++) {
      if (find.text('数据概况').evaluate().isNotEmpty ||
          find.text('本地参考数据暂不可用').evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('knowledge-search-entry')),
      findsOneWidget,
    );
    expect(find.text('数据概况'), findsOneWidget);
    expect(find.text('交通联合 TU'), findsOneWidget);
    await tester.tap(find.text('城市一卡通 CU'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('城市一卡通参考数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
          nfcAdapterStates: const Stream.empty(),
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

  test('2.x 实时会话使用原版发现与关闭', () async {
    final channel = _TagChannel();
    final app = AppDependencies(
      settingsStore: MemorySettingsStore(),
      bundle: MissingTestAssets(),
      database: testDatabase(),
      channel: channel,
      nfcAdapterStates: const Stream.empty(),
    );
    addTearDown(app.dispose);
    await app.init();
    final pending = app.scanOnceForGallery();
    await channel.waitForStart();
    final session = channel.starts.single;
    channel.deliver(session);
    await pending;
    expect(channel.stops, contains(session));
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
    return (_replies[sessionId] = Completer<NfcScanResult?>()).future;
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
