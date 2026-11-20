import { bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AsyncCallback } from '@kit.BasicServicesKit';
import { nfcController, tag } from '@kit.ConnectivityKit';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

class ScanSession {
  readonly id: string;
  readonly felicaOnly: boolean;
  scan?: MethodResult;
  callback?: AsyncCallback<tag.TagInfo>;
  link?: tag.TagSession;
  felica = false;
  claimed = false;
  closed = false;
  deadline?: number;
  tail: Promise<void> = Promise.resolve();
  retirement?: Promise<boolean>;
  readonly exchanges = new Set<MethodResult>();

  constructor(id: string, felicaOnly: boolean, scan: MethodResult) {
    this.id = id;
    this.felicaOnly = felicaOnly;
    this.scan = scan;
  }
}

export class NfcChannels {
  private static released: Promise<boolean> = Promise.resolve(true);
  private readonly ordinary: MethodChannel;
  private readonly octopus: MethodChannel;
  private readonly element: bundleManager.ElementName;
  private readonly sessions = new Map<string, ScanSession>();
  private active?: ScanSession;
  private foreground = false;
  private disposed = false;

  constructor(messenger: BinaryMessenger, element: bundleManager.ElementName) {
    this.element = element;
    this.ordinary = new MethodChannel(messenger, 'transit_card_analyzer/nfc');
    this.octopus = new MethodChannel(messenger, 'transit_card_analyzer/octopus_nfc');
    this.bind(this.ordinary, false);
    this.bind(this.octopus, true);
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    const session = this.active;
    if (session === undefined) return;
    if (foreground) {
      this.discoverAfterRelease(session);
    } else {
      this.retire(session);
    }
  }

  dispose(): void {
    this.disposed = true;
    if (this.active !== undefined) this.retire(this.active);
    this.ordinary.setMethodCallHandler(null);
    this.octopus.setMethodCallHandler(null);
    this.sessions.clear();
  }

  private bind(channel: MethodChannel, felicaOnly: boolean): void {
    channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        const method = call.method;
        const exchange = method === 'transceive' || method === 'transceiveFelica';
        if (method !== 'scanOnce' && method !== 'stopScan' &&
          (!exchange || (felicaOnly && method === 'transceive'))) {
          result.notImplemented();
          return;
        }
        const args: Object | null = call.args;
        const map = args instanceof Map;
        if (args != null && !map && (!exchange || felicaOnly)) {
          result.error('BAD_ARGUMENT', 'NFC 参数格式错误', null);
          return;
        }
        const hasId = map && call.hasArgument('sessionId');
        const id = hasId ? call.argument('sessionId') as string : undefined;
        if ((hasId && (typeof id !== 'string' || id.trim().length === 0)) || (felicaOnly && !hasId)) {
          result.error('BAD_ARGUMENT', 'sessionId 数据格式错误', null);
          return;
        }
        if (method === 'scanOnce') {
          this.scan(id ?? util.generateRandomUUID(), felicaOnly, result);
          return;
        }
        const session = id === undefined ? this.active : this.sessions.get(id);
        if (session === undefined) {
          if (id === undefined && method === 'stopScan') {
            result.success(null);
          } else {
            result.error('STALE_SESSION', 'NFC 会话已失效', null);
          }
          return;
        }
        if (method === 'stopScan') {
          this.acknowledgeStop(session, result);
        } else {
          const felica = method === 'transceiveFelica';
          const bytes: Object | null = map ? call.argument(felica ? 'frame' : 'apdu') : args;
          if (bytes instanceof Uint8Array) {
            this.exchange(session, Array.from(bytes), felica, result);
          } else if (Array.isArray(bytes)) {
            const payload = bytes as number[];
            if (!payload.every((value: number): boolean => Number.isInteger(value))) {
              this.fail(result, session, 'BAD_ARGUMENT', 'NFC 数据格式错误');
              return;
            }
            this.exchange(session, payload.map((value: number): number => value & 255), felica, result);
          } else {
            this.fail(result, session, 'BAD_ARGUMENT', 'NFC 数据格式错误');
          }
        }
      }
    });
  }

  private scan(id: string, felicaOnly: boolean, result: MethodResult): void {
    if (this.sessions.has(id)) {
      result.error('STALE_SESSION', 'NFC 会话 ID 不可重复使用', null);
      return;
    }
    if (this.active !== undefined) this.retire(this.active);
    const session = new ScanSession(id, felicaOnly, result);
    this.sessions.set(id, session);
    this.active = session;
    if (felicaOnly) {
      session.deadline = setTimeout(() => {
        if (!this.current(session) || session.scan === undefined) return;
        const details = this.details(session);
        details.set('discoveryPhase', session.claimed ? 'connecting' : 'waiting_for_tag');
        session.scan.error('NFC_DISCOVERY_TIMEOUT', '八达通发现超时，请重新贴卡。', details);
        session.scan = undefined;
        this.retire(session);
      }, 55000);
    }
    this.discoverAfterRelease(session);
  }

  private discoverAfterRelease(session: ScanSession): void {
    const barrier = NfcChannels.released;
    barrier.then((released: boolean): void => {
      if (!this.current(session) || !this.foreground || session.callback !== undefined) return;
      if (barrier !== NfcChannels.released) {
        this.discoverAfterRelease(session);
        return;
      }
      if (!released) {
        this.failScan(session, 'NFC_CLOSE_FAILED', '前一次读卡连接未能确认释放');
        return;
      }
      try {
        if (!canIUse('SystemCapability.Communication.NFC.Tag') || !nfcController.isNfcSupported()) {
          this.failScan(session, 'NFC_UNAVAILABLE', '当前设备没有可用的 NFC');
          return;
        }
        if (!nfcController.isNfcOpen()) {
          this.failScan(session, 'NFC_DISABLED', '请先打开系统 NFC');
          return;
        }
        const callback: AsyncCallback<tag.TagInfo> = (error, info): void => {
          if (!this.current(session) || !this.foreground || session.claimed) return;
          if (error?.code || !info) {
            this.failScan(session, 'NFC_SCAN_FAILED', '无法发现 NFC 标签');
            return;
          }
          if (session.felicaOnly && !info.technology.includes(tag.NFC_F)) return;
          session.claimed = true;
          this.connect(session, info);
        };
        tag.on('readerMode', this.element, session.felicaOnly ? [tag.NFC_F] :
          [tag.NFC_A, tag.NFC_B, tag.NFC_F, tag.NFC_V], callback);
        session.callback = callback;
      } catch (_) {
        this.failScan(session, 'NFC_SCAN_FAILED', '无法启动前台 NFC 读卡');
      }
    });
  }

  private connect(session: ScanSession, info: tag.TagInfo): void {
    try {
      const tech = info.technology;
      const isoDep = !session.felicaOnly && tech.includes(tag.ISO_DEP);
      const hasFelica = tech.includes(tag.NFC_F);
      session.felica = !isoDep && hasFelica;
      if (isoDep) session.link = tag.getIsoDep(info);
      if (session.felica) session.link = tag.getNfcF(info);
      session.link?.connect();
      session.link?.setTimeout(session.felica ? 3000 : 5000);
      const metadata = this.details(session);
      metadata.set('uid', this.hex(info.uid));
      const names = ['', 'NfcA', 'NfcB', 'IsoDep', 'NfcF', 'NfcV', 'Ndef', 'NdefFormatable',
        'MifareClassic', 'MifareUltralight'];
      metadata.set('technologies', tech.map((value: number): string => names[value] ?? `NFC ${value}`));
      metadata.set('isoDepConnected', isoDep);
      metadata.set('felicaConnected', session.felica);
      metadata.set('timestamp', new Date().toISOString());
      if (tech.includes(tag.NFC_A)) {
        this.readMetadata(metadata, 'atqa', () => tag.getNfcA(info).getAtqa());
        this.readMetadata(metadata, 'sak', () => [tag.getNfcA(info).getSak()]);
      }
      if (isoDep) {
        this.readMetadata(metadata, 'historicalBytes', () => tag.getIsoDep(info).getHistoricalBytes());
        this.readMetadata(metadata, 'hiLayerResponse', () => tag.getIsoDep(info).getHiLayerResponse());
        const historical = metadata.get('historicalBytes');
        if (historical !== undefined) metadata.set('ats', historical);
      }
      if (tech.includes(tag.NFC_B)) {
        this.readMetadata(metadata, 'nfcBApplicationData', () => tag.getNfcB(info).getRespAppData());
        this.readMetadata(metadata, 'nfcBProtocolInfo', () => tag.getNfcB(info).getRespProtocol());
      }
      if (hasFelica) {
        this.readMetadata(metadata, 'nfcFSystemCode', () => tag.getNfcF(info).getSystemCode());
        this.readMetadata(metadata, 'nfcFManufacturer', () => tag.getNfcF(info).getPmm());
      }
      this.clearDeadline(session);
      const reply = session.scan;
      session.scan = undefined;
      reply?.success(metadata);
    } catch (_) {
      this.failScan(session, 'NFC_SCAN_FAILED', '无法连接 NFC 标签，请重新贴卡');
    }
  }

  private exchange(session: ScanSession, bytes: number[], felica: boolean, reply: MethodResult): void {
    if (!this.current(session)) {
      this.fail(reply, session, 'STALE_SESSION', 'NFC 会话已失效');
      return;
    }
    const link = session.link;
    if (link === undefined || session.felica !== felica) {
      this.fail(reply, session, felica ? 'FELICA_NOT_CONNECTED' : 'TAG_NOT_CONNECTED', '卡片未连接');
      return;
    }
    if (bytes.length === 0 || session.exchanges.size >= 64) {
      this.fail(reply, session, bytes.length === 0 ? 'BAD_ARGUMENT' : 'NFC_BUSY',
        bytes.length === 0 ? 'NFC 数据不能为空' : 'NFC 指令队列已满');
      return;
    }
    session.exchanges.add(reply);
    session.tail = session.tail.then(async (): Promise<void> => {
      if (!this.current(session)) return;
      try {
        const response = await link.transmit(bytes);
        if (!session.exchanges.delete(reply)) return;
        if (response.length === 0) {
          this.fail(reply, session, 'TRANSCEIVE_FAILED', '卡片未返回响应');
        } else {
          reply.success(new Uint8Array(response));
        }
      } catch (_) {
        if (session.exchanges.delete(reply)) {
          this.fail(reply, session, 'TRANSCEIVE_FAILED', 'NFC 收发失败');
        }
      }
    });
  }

  private acknowledgeStop(session: ScanSession, reply: MethodResult): void {
    let waiting = true;
    const timeout = setTimeout((): void => {
      waiting = false;
      const details = this.details(session);
      details.set('closing', true);
      details.set('reason', 'close_timeout');
      reply.error('NFC_CLOSE_FAILED', 'NFC 连接仍在关闭', details);
    }, 10000);
    this.retire(session).then((released: boolean): void => {
      if (!waiting) return;
      clearTimeout(timeout);
      if (released) reply.success(null);
      else this.fail(reply, session, 'NFC_CLOSE_FAILED', '未能确认 NFC 连接关闭');
    });
  }

  private retire(session: ScanSession): Promise<boolean> {
    if (session.retirement !== undefined) return session.retirement;
    session.closed = true;
    if (this.active === session) this.active = undefined;
    this.clearDeadline(session);
    const scan = session.scan;
    session.scan = undefined;
    if (scan !== undefined) this.fail(scan, session, 'NFC_STOPPED', '扫描已停止');
    session.exchanges.forEach((reply: MethodResult): void => {
      this.fail(reply, session, 'NFC_STOPPED', '扫描已停止');
    });
    session.exchanges.clear();
    const link = session.link;
    const callback = session.callback;
    const previous = NfcChannels.released;
    session.retirement = previous.then(async (earlier: boolean): Promise<boolean> => {
      let released = earlier;
      if (callback !== undefined) {
        try { tag.off('readerMode', this.element, callback); } catch (_) { released = false; }
      }
      await session.tail;
      if (link !== undefined) {
        try { link.resetConnection(); } catch (_) { released = false; }
      }
      session.link = undefined;
      session.callback = undefined;
      return released;
    });
    NfcChannels.released = session.retirement;
    return session.retirement;
  }

  private current(session: ScanSession): boolean {
    return !this.disposed && !session.closed && this.active === session;
  }

  private clearDeadline(session: ScanSession): void {
    if (session.deadline === undefined) return;
    clearTimeout(session.deadline);
    session.deadline = undefined;
  }

  private details(session: ScanSession): Map<string, Object> {
    const details = new Map<string, Object>();
    details.set('sessionId', session.id);
    return details;
  }

  private fail(reply: MethodResult, session: ScanSession, code: string, message: string): void {
    reply.error(code, message, this.details(session));
  }

  private failScan(session: ScanSession, code: string, message: string): void {
    const reply = session.scan;
    session.scan = undefined;
    if (reply !== undefined) this.fail(reply, session, code, message);
    this.retire(session);
  }

  private hex(bytes: number[]): string {
    return bytes.map((value: number): string => (value & 255).toString(16).toUpperCase().padStart(2, '0')).join(' ');
  }

  private readMetadata(metadata: Map<string, Object>, name: string, read: () => number[]): void {
    try {
      const bytes = read();
      if (bytes.length > 0) metadata.set(name, this.hex(bytes));
    } catch (_) {}
  }
}
