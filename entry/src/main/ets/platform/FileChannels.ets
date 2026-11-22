import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

const MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;

class DocumentError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export class FileChannels {
  private readonly archives: MethodChannel;
  private readonly exports: MethodChannel;
  private readonly context: common.UIAbilityContext;
  private pending?: MethodResult;
  private disposed = false;

  constructor(messenger: BinaryMessenger, context: common.UIAbilityContext) {
    this.context = context;
    this.archives = new MethodChannel(messenger, 'transit_card_analyzer/archive_documents');
    this.archives.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.handle(call, result, true);
      }
    });
    this.exports = new MethodChannel(messenger, 'transit_card_analyzer/export');
    this.exports.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.handle(call, result, false);
      }
    });
  }

  private async handle(call: MethodCall, result: MethodResult, archive: boolean): Promise<void> {
    const opening = archive && call.method === 'openJson';
    if (!opening && call.method !== (archive ? 'saveJson' : 'saveFile')) {
      result.notImplemented();
      return;
    }
    if (this.disposed) {
      result.success(null);
      return;
    }
    if (this.pending) {
      result.error('DOCUMENT_IN_PROGRESS', '已有文件操作正在进行', null);
      return;
    }
    this.pending = result;
    try {
      const output = opening ? await this.openJson() : await this.saveFile(call, archive);
      if (this.pending === result) result.success(output);
    } catch (error) {
      if (this.pending !== result) return;
      if (error instanceof DocumentError) {
        result.error(error.code, error.message, null);
      } else {
        result.error(opening ? 'DOCUMENT_READ_FAILED' : 'DOCUMENT_WRITE_FAILED',
          opening ? '无法读取所选文件，请重新选择。' : '无法保存到所选位置，请重试。',
          (error as BusinessError).code ?? null);
      }
    } finally {
      if (this.pending === result) this.pending = undefined;
    }
  }

  private async openJson(): Promise<Map<string, string> | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json'];
    const uris = await new picker.DocumentViewPicker(this.context).select(options);
    const uri = uris[0];
    if (!uri || this.disposed) return null;

    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      this.checkArchiveSize((await fileIo.stat(file.fd)).size);
      const decoder = util.TextDecoder.create('utf-8', { fatal: true });
      const buffer = new ArrayBuffer(64 * 1024);
      const chunks: string[] = [];
      let total = 0;
      while (!this.disposed) {
        const count = await fileIo.read(file.fd, buffer);
        total += count;
        this.checkArchiveSize(total);
        try {
          chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: count !== 0 }));
        } catch (_) {
          throw new DocumentError('DOCUMENT_INVALID_UTF8', '请选择 UTF-8 编码的 JSON 文件。');
        }
        if (count === 0) break;
      }
      const document = new Map<string, string>();
      document.set('name', this.displayName(uri, '卡片数据.json'));
      document.set('content', chunks.join(''));
      return document;
    } finally {
      await fileIo.close(file);
    }
  }

  private async saveFile(call: MethodCall, archive: boolean): Promise<string | null> {
    const name = call.argument('fileName') as string;
    const content = call.argument('content') as string;
    if (typeof name !== 'string' || name.length > 240 || /[\x00-\x1f\\/:*?"<>|]/.test(name) ||
      typeof content !== 'string') {
      throw new DocumentError('BAD_ARGUMENT', '缺少有效的文件名或文件内容。');
    }
    const suffix = name.slice(name.lastIndexOf('.')).toLowerCase();
    if (suffix !== '.json' && (archive || suffix !== '.txt')) {
      throw new DocumentError('BAD_ARGUMENT', '文件类型不受支持。');
    }
    const bytes = content.length === 0 ? new Uint8Array(0) : util.TextEncoder.create().encodeInto(content);
    if (archive) this.checkArchiveSize(bytes.byteLength);

    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [name];
    options.fileSuffixChoices = [suffix];
    const uris = await new picker.DocumentViewPicker(this.context).save(options);
    const uri = uris[0];
    if (!uri || this.disposed) return null;

    const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      let remaining = bytes.buffer;
      while (remaining.byteLength > 0) {
        const written = await fileIo.write(file.fd, remaining);
        if (written === remaining.byteLength) break;
        if (written <= 0) throw new Error('Incomplete file write');
        remaining = remaining.slice(written);
      }
    } finally {
      await fileIo.close(file);
    }
    return this.displayName(uri, name);
  }

  private checkArchiveSize(size: number): void {
    if (size > MAX_ARCHIVE_BYTES) {
      throw new DocumentError('DOCUMENT_TOO_LARGE', 'JSON 文件不得大于 32 MiB，请分卡导出。');
    }
  }

  private displayName(uri: string, fallback: string): string {
    try {
      return new fileUri.FileUri(uri).name || fallback;
    } catch (_) {
      return fallback;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.archives.setMethodCallHandler(null);
    this.exports.setMethodCallHandler(null);
    this.pending?.success(null);
    this.pending = undefined;
  }
}
