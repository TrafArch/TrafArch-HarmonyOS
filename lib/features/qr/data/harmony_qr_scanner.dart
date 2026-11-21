import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'qr_dart_decoder.dart';

class HarmonyQrScanner extends MobileScannerPlatform {
  static const channel = MethodChannel('transit_card_analyzer/qr_camera');

  final _captures = StreamController<BarcodeCapture?>.broadcast();
  final _torch = StreamController<TorchState>.broadcast();
  int? _textureId;
  int _session = 0;

  @override
  Stream<BarcodeCapture?> get barcodesStream => _captures.stream;

  @override
  Stream<TorchState> get torchStateStream => _torch.stream;

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    try {
      final view = (await channel.invokeMapMethod<String, Object>('start'))!;
      _textureId = view['textureId'] as int;
      final attributes = MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: view['torch'] == true
            ? TorchState.off
            : TorchState.unavailable,
        size: Size(
          (view['width'] as num).toDouble(),
          (view['height'] as num).toDouble(),
        ),
      );
      unawaited(_scan(++_session));
      return attributes;
    } on PlatformException catch (error) {
      throw MobileScannerException(
        errorCode: error.code == 'permission_denied'
            ? MobileScannerErrorCode.permissionDenied
            : MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(message: error.message),
      );
    } catch (_) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(message: '无法启动鸿蒙相机'),
      );
    }
  }

  Future<void> _scan(int session) async {
    var emptyFrames = 0;
    try {
      while (session == _session) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (session != _session) return;
        final frame = await channel.invokeMapMethod<String, Object>(
          'readFrame',
        );
        if (session != _session) return;
        if (frame == null) {
          if (++emptyFrames >= 25) throw StateError('相机未返回预览画面');
          continue;
        }
        emptyFrames = 0;
        final pixels = frame['pixels'] as Uint8List;
        final width = frame['width'] as int;
        final height = frame['height'] as int;
        final result = await Isolate.run(
          () => decodeQrFromLuminance(pixels, width, height),
        );
        if (session != _session || result == null) continue;
        _captures.add(
          BarcodeCapture(
            barcodes: [
              Barcode(
                format: BarcodeFormat.qrCode,
                rawDecodedBytes: DecodedBarcodeBytes(
                  bytes: Uint8List.fromList(result.payload),
                ),
              ),
            ],
          ),
        );
        return;
      }
    } catch (_) {
      if (session == _session) {
        _captures.addError(const MobileScannerBarcodeException('无法读取相机画面，请重试'));
      }
    }
  }

  @override
  Widget buildCameraView() => switch (_textureId) {
    final int id => Texture(textureId: id),
    null => const SizedBox.shrink(),
  };

  @override
  Future<void> toggleTorch() async {
    final on = await channel.invokeMethod<bool>('toggleTorch');
    _torch.add(on == true ? TorchState.on : TorchState.off);
  }

  @override
  Future<void> stop() async {
    _session++;
    _textureId = null;
    await channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> dispose() => stop().catchError((Object _) {});
}
