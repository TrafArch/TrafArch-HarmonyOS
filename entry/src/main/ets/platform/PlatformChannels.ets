import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

export class PlatformChannels {
  private readonly paths: MethodChannel;
  private readonly browser: MethodChannel;
  private readonly appInfo: MethodChannel;

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
    this.appInfo = new MethodChannel(messenger, 'transit_card_analyzer/app_info');
    this.appInfo.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method !== 'getPackageInfo') {
          result.notImplemented();
          return;
        }
        const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
        bundleManager.getBundleInfoForSelf(flags).then((info) => {
          const fields = new Map<string, string | number>();
          fields.set('versionName', info.versionName);
          fields.set('versionCode', info.versionCode);
          result.success(fields);
        }, (error: BusinessError) => {
          result.error('APP_INFO_UNAVAILABLE', '无法读取鸿蒙应用版本', error.code);
        });
      }
    });
  }

  dispose(): void {
    this.paths.setMethodCallHandler(null);
    this.browser.setMethodCallHandler(null);
    this.appInfo.setMethodCallHandler(null);
  }
}
