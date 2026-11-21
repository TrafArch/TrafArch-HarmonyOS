import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart';
import 'package:transit_card_analyzer/features/qr/application/qr_acquisition.dart';
import 'package:transit_card_analyzer/features/qr/data/harmony_qr_scanner.dart';
import 'package:transit_card_analyzer/features/qr/data/qr_dart_decoder.dart';
import 'package:transit_card_analyzer/features/qr/domain/qr_barcode_payload.dart';
import 'package:transit_card_analyzer/platform/qr/qr_image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('鸿蒙相机预览灰度帧通过通道保留乘车码原始字节', () async {
    final payload = Uint8List.fromList([0x80, 0, 0xff, 0, 0x7f]);
    final fixture = _renderPayload(QrPayload.fromTypedData(payload));
    final pixels = Uint8List(fixture.side * fixture.side);
    for (var index = 0; index < pixels.length; index++) {
      pixels[index] = fixture.rgba[4 * index];
    }
    final calls = <String>[];
    messenger.setMockMethodCallHandler(HarmonyQrScanner.channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'start' => {
          'textureId': 3,
          'width': 720,
          'height': 1280,
          'torch': true,
        },
        'readFrame' => {
          'width': fixture.side,
          'height': fixture.side,
          'pixels': pixels,
        },
        'stop' => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(HarmonyQrScanner.channel, null),
    );
    final scanner = HarmonyQrScanner();
    final capture = scanner.barcodesStream.first;
    final view = await scanner.start(
      const StartOptions(
        cameraDirection: CameraFacing.back,
        cameraLensType: CameraLensType.any,
        cameraResolution: null,
        detectionSpeed: DetectionSpeed.noDuplicates,
        detectionTimeoutMs: 0,
        formats: [BarcodeFormat.qrCode],
        returnImage: false,
        torchEnabled: false,
        invertImage: false,
        autoZoom: false,
        initialZoom: null,
      ),
    );
    try {
      expect(view.size, const ui.Size(720, 1280));
      expect(view.currentTorchMode, TorchState.off);
      final detected = await capture.timeout(const Duration(seconds: 5));
      expect(qrPayloadOfBarcodes(detected!.barcodes), payload);
    } finally {
      await scanner.stop();
    }
    expect(calls, ['start', 'readFrame', 'stop']);
  });

  test('鸿蒙相册解码保留二进制，随后释放所选图片', () async {
    final payload = Uint8List.fromList([0x80, 0, 0xef, 0x22, 0xff]);
    final fixture = _renderPayload(QrPayload.fromTypedData(payload));
    final directory = await Directory.systemTemp.createTemp('trafarch-qr-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/selected.png');
    final buffer = await ui.ImmutableBuffer.fromUint8List(fixture.rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: fixture.side,
      height: fixture.side,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    try {
      final png = (await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      await file.writeAsBytes(Uint8List.sublistView(png));
    } finally {
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
    final calls = <String>[];
    messenger.setMockMethodCallHandler(qrImagePickerChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickImage') return file.path;
      expect(call.method, 'releaseImage');
      expect(call.arguments, {'path': file.path});
      await file.delete();
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(qrImagePickerChannel, null),
    );
    final result = await const QrAcquisition(useDartGallery: true).gallery();
    expect(result, isA<AcquiredQrPayload>());
    expect((result as AcquiredQrPayload).bytes, payload);
    expect(result.origin, QrPayloadOrigin.galleryDart);
    expect(calls, ['pickImage', 'releaseImage']);
    expect(await file.exists(), isFalse);
  });

  group('decodeQrFromRgba', () {
    test('可识别二维码并还原原始字节', () {
      const text = 'TrafArch-qr-dart-fallback-2026';
      final image = _renderQr(text);
      final decoded = decodeQrFromRgba(image.rgba, image.side, image.side);
      expect(decoded, isNotNull);
      expect(decoded!.payload, utf8.encode(text));
    });

    test('二进制载荷保留零字节和高位字节，不包含 QR 模式和填充码字', () {
      final payload = Uint8List.fromList([0, 0x80, 0xFF, 0x54, 0, 0x7F]);
      final image = _renderPayload(QrPayload.fromTypedData(payload));
      final decoded = decodeQrFromRgba(image.rgba, image.side, image.side);
      expect(decoded?.payload, [0, 0x80, 0xFF, 0x54, 0, 0x7F]);
    });

    test('多个 byte 段按原顺序拼接', () {
      final payload = QrPayload()
        ..addTypedData(Uint8List.fromList([0x80, 0, 0xFF]))
        ..addTypedData(Uint8List.fromList([1, 2, 3]));
      final image = _renderPayload(payload);
      final decoded = decodeQrFromRgba(image.rgba, image.side, image.side);
      expect(decoded?.payload, [0x80, 0, 0xFF, 1, 2, 3]);
    });

    test('纯数字模式使用解码文本恢复载荷', () {
      final image = _renderPayload(QrPayload()..addNumeric('001234567890'));
      final decoded = decodeQrFromRgba(image.rgba, image.side, image.side);
      expect(decoded?.payload, utf8.encode('001234567890'));
    });

    test('纯色图片返回 null', () {
      const side = 200;
      final rgba = Uint8List(side * side * 4)
        ..fillRange(0, side * side * 4, 0xFF);
      expect(decodeQrFromRgba(rgba, side, side), isNull);
    });

    test('入参无效返回 null', () {
      expect(decodeQrFromRgba(Uint8List(0), 0, 0), isNull);
      expect(decodeQrFromRgba(Uint8List(4), 10, 10), isNull);
    });
  });
}

/// 将二维码渲染为 RGBA 像素：每模块 [scale] 像素，四周 [quietZone] 模块静区。
({Uint8List rgba, int side}) _renderQr(
  String text, {
  int scale = 8,
  int quietZone = 4,
}) => _renderPayload(
  QrPayload.fromString(text),
  scale: scale,
  quietZone: quietZone,
);

({Uint8List rgba, int side}) _renderPayload(
  QrPayload payload, {
  int scale = 8,
  int quietZone = 4,
}) {
  final qrImage = QrImage(
    QrCode(payload: payload, errorCorrectLevel: QrErrorCorrectLevel.low),
  );
  final modules = qrImage.moduleCount;
  final side = (modules + quietZone * 2) * scale;
  final rgba = Uint8List(side * side * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
    rgba[i + 1] = 0xFF;
    rgba[i + 2] = 0xFF;
    rgba[i + 3] = 0xFF;
  }
  for (var row = 0; row < modules; row++) {
    for (var col = 0; col < modules; col++) {
      if (!qrImage.isDark(row, col)) continue;
      final startX = (col + quietZone) * scale;
      final startY = (row + quietZone) * scale;
      for (var dy = 0; dy < scale; dy++) {
        var offset = ((startY + dy) * side + startX) * 4;
        for (var dx = 0; dx < scale; dx++) {
          rgba[offset] = 0;
          rgba[offset + 1] = 0;
          rgba[offset + 2] = 0;
          offset += 4;
        }
      }
    }
  }
  return (rgba: rgba, side: side);
}
