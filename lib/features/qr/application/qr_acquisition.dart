import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/qr_barcode_payload.dart';
import '../data/qr_dart_decoder.dart';
import '../../../platform/qr/qr_image_picker.dart';

enum QrPayloadOrigin { camera, galleryMlkit, galleryDart }

sealed class QrAcquisitionResult {
  const QrAcquisitionResult();
}

class AcquiredQrPayload extends QrAcquisitionResult {
  AcquiredQrPayload(List<int> bytes, this.origin)
    : bytes = List<int>.unmodifiable(bytes);
  final List<int> bytes;
  final QrPayloadOrigin origin;
}

class QrAcquisitionCancelled extends QrAcquisitionResult {
  const QrAcquisitionCancelled();
}

class QrAcquisitionFailed extends QrAcquisitionResult {
  const QrAcquisitionFailed(this.message);
  final String message;
}

/// Acquisition policy and decoder lifetime, independent of navigation/dialogs.
/// Bytes are passed through; encoding fallback remains in the existing decoders.
class QrAcquisition {
  const QrAcquisition({this.useDartGallery = false});

  final bool useDartGallery;

  Future<QrAcquisitionResult> scan({
    required Future<List<int>?> Function() openCamera,
  }) async {
    return _payload(await openCamera(), QrPayloadOrigin.camera);
  }

  Future<QrAcquisitionResult> gallery() async {
    try {
      final path = await pickQrImageFromGallery();
      if (path == null) return const QrAcquisitionCancelled();
      if (useDartGallery) {
        try {
          final bytes = await decodeQrFromImageFile(path);
          return bytes == null || bytes.isEmpty
              ? const QrAcquisitionFailed('未在该图片中识别到二维码')
              : AcquiredQrPayload(bytes, QrPayloadOrigin.galleryDart);
        } finally {
          await releaseQrImage(path).catchError((Object _) {});
        }
      }
      var mlkitUnavailable = false;
      MobileScannerController? controller;
      try {
        controller = MobileScannerController();
        final capture = await controller.analyzeImage(
          path,
          formats: const [BarcodeFormat.qrCode],
        );
        final bytes = qrPayloadOfBarcodes(
          capture?.barcodes ?? const <Barcode>[],
        );
        if (bytes != null && bytes.isNotEmpty) {
          return AcquiredQrPayload(bytes, QrPayloadOrigin.galleryMlkit);
        }
      } catch (_) {
        mlkitUnavailable = true;
      } finally {
        try {
          await controller?.dispose();
        } catch (_) {
          // Cleanup failure must not discard successfully acquired bytes.
        }
      }
      final bytes = await decodeQrFromImageFile(path);
      if (bytes != null && bytes.isNotEmpty) {
        return AcquiredQrPayload(bytes, QrPayloadOrigin.galleryDart);
      }
      return QrAcquisitionFailed(
        mlkitUnavailable ? '图片识别组件不可用，内置解码也未识别到二维码' : '未在该图片中识别到二维码',
      );
    } on PlatformException catch (error) {
      return QrAcquisitionFailed(error.message ?? '从相册导入失败，请重试');
    } catch (_) {
      return const QrAcquisitionFailed('从相册导入失败，请重试');
    }
  }

  QrAcquisitionResult _payload(List<int>? bytes, QrPayloadOrigin origin) =>
      bytes == null || bytes.isEmpty
      ? const QrAcquisitionCancelled()
      : AcquiredQrPayload(bytes, origin);
}
