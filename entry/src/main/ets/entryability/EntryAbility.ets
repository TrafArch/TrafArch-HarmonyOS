import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { NfcChannels } from '../platform/NfcChannels';
import { PlatformChannels } from '../platform/PlatformChannels';

export default class EntryAbility extends FlutterAbility {
  private nfc?: NfcChannels;
  private platform?: PlatformChannels;
  private foreground = false;

  configureFlutterEngine(engine: FlutterEngine): void {
    super.configureFlutterEngine(engine);
    const messenger = engine.getDartExecutor().getBinaryMessenger();
    const info = this.context.abilityInfo;
    this.nfc = new NfcChannels(messenger, {
      bundleName: info.bundleName, moduleName: info.moduleName, abilityName: info.name
    });
    this.nfc.setForeground(this.foreground);
    this.platform = new PlatformChannels(messenger, this.context);
  }

  onForeground(): void {
    this.foreground = true;
    super.onForeground();
    this.nfc?.setForeground(true);
  }

  onBackground(): void {
    this.foreground = false;
    this.nfc?.setForeground(false);
    super.onBackground();
  }

  cleanUpFlutterEngine(engine: FlutterEngine): void {
    this.nfc?.dispose();
    this.platform?.dispose();
    this.nfc = undefined;
    this.platform = undefined;
    super.cleanUpFlutterEngine(engine);
  }
}
