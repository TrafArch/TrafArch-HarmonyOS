import { common } from '@kit.AbilityKit';
import { FlutterPage } from '@ohos/flutter_ohos';

const storage = LocalStorage.getShared();

@Entry(storage)
@Component
struct Index {
  @LocalStorageLink('viewId') viewId: string = '';

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.emit('EVENT_BACK_PRESS');
    return true;
  }
}
