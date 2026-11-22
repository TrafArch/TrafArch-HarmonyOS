import 'package:flutter/services.dart';

/// 将日志或记录保存到用户选择的位置。
abstract class LogExporter {
  /// 返回保存后的文件名，用户取消时返回 null，写入失败时抛出异常。
  Future<String?> saveFile(String fileName, String content);
}

class MethodChannelLogExporter implements LogExporter {
  static const _channel = MethodChannel('transit_card_analyzer/export');

  const MethodChannelLogExporter();

  @override
  Future<String?> saveFile(String fileName, String content) async {
    final name = await _channel.invokeMethod<String>('saveFile', {
      'fileName': fileName,
      'content': content,
    });
    if (name != null && name.trim().isEmpty) {
      throw PlatformException(code: 'EXPORT_FAILED', message: '未能确认文件已保存，请重试。');
    }
    return name;
  }
}
