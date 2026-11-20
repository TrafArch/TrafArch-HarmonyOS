import { common } from '@kit.AbilityKit';
import { CardRecord, money, ScanMode, Wallet } from '../nfc/CardRead';
import { HarmonyNfcReader } from '../nfc/HarmonyNfcReader';
import { NfcScanSession, ScanPhase, ScanStatus } from '../nfc/NfcScanSession';

@Entry
@Component
struct Index {
  @State status: ScanStatus = new ScanStatus();
  @State showRaw: boolean = false;
  private session?: NfcScanSession;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const reader = new HarmonyNfcReader({
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      moduleName: context.abilityInfo.moduleName
    });
    this.session = new NfcScanSession(reader, (status: ScanStatus) => { this.status = status; });
  }

  onPageHide(): void {
    this.session?.cancel();
    this.showRaw = false;
    this.status = new ScanStatus();
  }

  aboutToDisappear(): void {
    this.session?.cancel();
  }

  private start(mode: ScanMode): void {
    this.showRaw = false;
    this.session?.start(mode);
  }

  @Builder
  walletView(wallet: Wallet) {
    Column({ space: 6 }) {
      Text(wallet.name).fontSize(21).fontWeight(FontWeight.Bold)
      if (wallet.currency.length > 0) {
        Text(wallet.balance === null ? '余额未读到' : `余额 ${money(wallet.balance, wallet.currency)}`)
      }
      if (wallet.serial) { Text(`卡号尾号 ${wallet.serial.slice(-4)}`) }
      if (wallet.city) { Text(`城市原码 ${wallet.city}`) }
      if (wallet.validity) { Text(`有效期至 ${wallet.validity}`) }
      if (wallet.note) { Text(wallet.note) }
      ForEach(wallet.records, (row: CardRecord) => {
        Column({ space: 4 }) {
          Text(`${row.source} #${row.slot}　${row.detail || '未解码记录'}`).fontSize(15)
          if (this.showRaw) { Text(row.raw).fontSize(13) }
        }.alignItems(HorizontalAlign.Start)
      }, (row: CardRecord) => `${row.source}:${row.slot}`)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('交通卡读取').fontSize(28).fontWeight(FontWeight.Bold)
        Text('将一张卡贴近手机。仅读取公开数据，不充值、不写卡，结果不保存。').fontSize(16)
        Text(this.status.message).fontSize(18)
        if (this.status.phase === ScanPhase.Waiting || this.status.phase === ScanPhase.Reading) {
          Button('取消读取').onClick(() => { this.session?.cancel(); })
        } else {
          Button('全量读取').onClick(() => { this.start(ScanMode.Full); })
          Button('仅查八达通余额').onClick(() => { this.start(ScanMode.Octopus); })
          Button('仅验证 ISO-DEP 通信').onClick(() => { this.start(ScanMode.Probe); })
        }
        if (this.status.wallets.length) {
          Button(this.showRaw ? '隐藏记录原文' : '查看记录原文').onClick(() => { this.showRaw = !this.showRaw; })
          ForEach(this.status.wallets, (wallet: Wallet) => {
            Divider()
            this.walletView(wallet)
          }, (wallet: Wallet) => wallet.name)
        }
        if (this.status.metadata.length) {
          Text(this.status.metadata.join('\n')).fontSize(13)
        }
      }
      .width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart)
  }
}
