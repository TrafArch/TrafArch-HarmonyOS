import { common } from '@kit.AbilityKit';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

export class PlatformChannels {
  private readonly paths: MethodChannel;
  private readonly browser: MethodChannel;

  constructor(messenger: BinaryMessenger, context: common.UIAbilityContext) {
    this.paths = new MethodChannel(messenger, 'plugins.flutter.io/path_provider');
    this.paths.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        switch (call.method) {
          case 'getApplicationDocumentsDirectory':
          case 'getApplicationSupportDirectory':
            result.success(context.filesDir);
            break;
          case 'getTemporaryDirectory':
          case 'getApplicationCacheDirectory':
            result.success(context.cacheDir);
            break;
          default:
            result.notImplemented();
        }
      }
    });
    this.browser = new MethodChannel(messenger, 'transit_card_analyzer/browser');
    this.browser.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method !== 'openCustomTab') {
          result.notImplemented();
          return;
        }
        const uri = call.argument('url') as string;
        if (typeof uri !== 'string' || !uri.startsWith('https://')) {
          result.success(null);
          return;
        }
        context.openLink(uri).then(() => result.success('default_browser'), () => result.success(null));
      }
    });
  }

  dispose(): void {
    this.paths.setMethodCallHandler(null);
    this.browser.setMethodCallHandler(null);
  }
}
