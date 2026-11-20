import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transit_card_analyzer/app/app_dependencies.dart';
import 'package:transit_card_analyzer/app/harmony_app.dart';
import 'package:transit_card_analyzer/app/harmony_gallery_controller.dart';
import 'package:transit_card_analyzer/gallery/gallery_app.dart';
import 'package:transit_card_analyzer/gallery/gallery_controller.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_models.dart';
import 'package:transit_card_analyzer/platform/nfc/nfc_service.dart';
import 'package:transit_card_analyzer/platform/storage/settings_store.dart';

import 'support/test_database.dart';

void main() {
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
