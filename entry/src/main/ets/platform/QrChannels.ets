import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BinaryMessenger, MethodCall, MethodChannel, MethodResult, SurfaceTextureEntry, TextureRegistry } from '@ohos/flutter_ohos';

export class QrChannels {
  private readonly scanner: MethodChannel;
  private readonly picker: MethodChannel;
  private readonly context: common.UIAbilityContext;
  private readonly textures: TextureRegistry;
  private cameraWork: Promise<void> = Promise.resolve();
  private active?: QrCamera;
  private picking = false;
  private disposed = false;
  private cachedImage?: string;
  private imageId = 0;

  constructor(messenger: BinaryMessenger, context: common.UIAbilityContext, textures: TextureRegistry) {
    this.context = context;
    this.textures = textures;
    this.scanner = new MethodChannel(messenger, 'transit_card_analyzer/qr_camera');
    this.scanner.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.cameraWork = this.cameraWork.then(() => this.handleCamera(call, result));
      }
    });
    this.picker = new MethodChannel(messenger, 'transit_card_analyzer/qr_image');
    this.picker.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method === 'pickImage') {
          this.pickImage(result);
        } else if (call.method === 'releaseImage') {
          this.releaseImage(call.argument('path') as string).then(() => result.success(null));
        } else {
          result.notImplemented();
        }
      }
    });
  }

  private async handleCamera(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      if (this.disposed) {
        result.error('camera_unavailable', '相机已关闭', null);
        return;
      }
      switch (call.method) {
        case 'start': {
          await this.stop();
          const access = abilityAccessCtrl.createAtManager();
          const grant = await access.requestPermissionsFromUser(this.context, ['ohos.permission.CAMERA']);
          if (grant.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            result.error('permission_denied', '请在系统设置中允许 TrafArch 使用相机', null);
            return;
          }
          if (this.disposed) {
            result.error('camera_unavailable', '相机已关闭', null);
            return;
          }
          this.active = new QrCamera(this.context, this.textures);
          result.success(await this.active.start());
          break;
        }
        case 'stop':
          await this.stop();
          result.success(null);
          break;
        case 'readFrame':
          result.success(await this.active?.readFrame() ?? null);
          break;
        case 'toggleTorch':
          result.success(this.active?.toggleTorch() ?? false);
          break;
        default:
          result.notImplemented();
      }
    } catch (error) {
      if (call.method === 'start') await this.stop();
      const failure = error as BusinessError;
      result.error('camera_unavailable', failure.message, failure.code ?? null);
    }
  }

  private async stop(): Promise<void> {
    const active = this.active;
    this.active = undefined;
    await active?.close();
  }

  private async pickImage(result: MethodResult): Promise<void> {
    if (this.picking) {
      result.error('picker_busy', '相册已经打开', null);
      return;
    }
    this.picking = true;
    let path: string | undefined;
    try {
      await this.releaseImage(this.cachedImage);
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const selection = await new photoAccessHelper.PhotoViewPicker().select(options);
      const uri = selection.photoUris[0];
      if (!uri || this.disposed) {
        result.success(null);
        return;
      }
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      try {
        if ((await fileIo.stat(file.fd)).size > 20 * 1024 * 1024) {
          result.error('image_too_large', '请选择不大于 20 MB 的图片', null);
          return;
        }
        path = `${this.context.cacheDir}/trafarch-qr-${Date.now()}-${++this.imageId}.img`;
        await fileIo.copyFile(file.fd, path);
      } finally {
        await fileIo.close(file);
      }
      this.cachedImage = path;
      if (this.disposed) {
        await this.releaseImage(path);
        result.success(null);
      } else {
        result.success(path);
      }
    } catch (error) {
      if (path) await fileIo.unlink(path).catch(() => {});
      const failure = error as BusinessError;
      result.error('pick_failed', '无法读取所选图片，请重试', failure.code ?? null);
    } finally {
      this.picking = false;
    }
  }

  private async releaseImage(path?: string): Promise<void> {
    if (!path || path !== this.cachedImage) return;
    this.cachedImage = undefined;
    await fileIo.unlink(path).catch(() => {});
  }

  dispose(): void {
    this.disposed = true;
    this.scanner.setMethodCallHandler(null);
    this.picker.setMethodCallHandler(null);
    this.cameraWork = this.cameraWork.then(() => this.stop());
    this.releaseImage(this.cachedImage);
  }
}

class QrCamera {
  private readonly context: common.UIAbilityContext;
  private readonly textures: TextureRegistry;
  private manager?: camera.CameraManager;
  private input?: camera.CameraInput;
  private preview?: camera.PreviewOutput;
  private analysis?: camera.PreviewOutput;
  private receiver?: image.ImageReceiver;
  private texture?: SurfaceTextureEntry;
  private session?: camera.PhotoSession;
  private hasFrame = false;
  private torch = false;
  private rgbaPreview = false;

  constructor(context: common.UIAbilityContext, textures: TextureRegistry) {
    this.context = context;
    this.textures = textures;
  }

  async start(): Promise<Map<string, number | boolean>> {
    const manager = this.manager = camera.getCameraManager(this.context);
    const device = manager.getSupportedCameras().find((item) => item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK);
    if (!device) throw new Error('未找到后置相机');
    const mode = camera.SceneMode.NORMAL_PHOTO;
    const profiles = manager.getSupportedOutputCapability(device, mode).previewProfiles;
    profiles.sort((left, right) => Math.abs(left.size.width * left.size.height - 921600) -
      Math.abs(right.size.width * right.size.height - 921600));
    const profile = profiles.find((item) => item.format === camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP) ??
      profiles.find((item) => item.format === camera.CameraFormat.CAMERA_FORMAT_RGBA_8888);
    if (!profile) throw new Error('相机不支持二维码识别所需的预览格式');
    this.rgbaPreview = profile.format === camera.CameraFormat.CAMERA_FORMAT_RGBA_8888;
    const size = profile.size;
    const input = this.input = manager.createCameraInput(device);
    await input.open();
    const texture = this.texture = this.textures.registerTexture(this.textures.getTextureId());
    this.textures.setTextureBufferSize(texture.getTextureId(), size.width, size.height);
    const receiver = image.createImageReceiver({ size: size, capacity: 4 });
    if (!receiver) throw new Error('无法创建相机图像接收器');
    this.receiver = receiver;
    receiver.on('imageArrival', () => { this.hasFrame = true; });
    const preview = this.preview = manager.createPreviewOutput(profile, texture.getSurfaceId().toString());
    const analysis = this.analysis = manager.createPreviewOutput(profile, await receiver.getReceivingSurfaceId());
    const session = this.session = manager.createSession<camera.PhotoSession>(mode);
    session.beginConfig();
    session.addInput(input);
    session.addOutput(preview);
    session.addOutput(analysis);
    await session.commitConfig();
    const rotation = preview.getPreviewRotation();
    preview.setPreviewRotation(rotation);
    const swapped = rotation === camera.ImageRotation.ROTATION_90 || rotation === camera.ImageRotation.ROTATION_270;
    const focus = camera.FocusMode.FOCUS_MODE_CONTINUOUS_AUTO;
    if (session.isFocusModeSupported(focus)) session.setFocusMode(focus);
    await session.start();
    const attributes = new Map<string, number | boolean>();
    attributes.set('textureId', texture.getTextureId());
    attributes.set('width', swapped ? size.height : size.width);
    attributes.set('height', swapped ? size.width : size.height);
    attributes.set('torch', manager.isTorchModeSupported(camera.TorchMode.ON));
    return attributes;
  }

  async readFrame(): Promise<Map<string, number | Uint8Array> | null> {
    if (!this.receiver || !this.hasFrame) return null;
    this.hasFrame = false;
    const frame = await this.receiver.readLatestImage().catch(() => null);
    if (!frame) return null;
    try {
      const data = frame.getBufferData();
      const component = data?.rowStride[0] ? undefined : await frame.getComponent(image.ComponentType.JPEG);
      const size = frame.size;
      const rowStride = component?.rowStride ?? data?.rowStride[0] ?? 0;
      const pixelSize = this.rgbaPreview ? 4 : 1;
      const pixelStride = component ? pixelSize : (data?.pixelStride[0] || pixelSize);
      const rowBytes = (size.width - 1) * pixelStride + pixelSize;
      const bytes = component?.byteBuffer ?? data?.byteBuffer;
      if (!bytes || size.width <= 0 || size.height <= 0 || pixelStride < pixelSize ||
        rowStride < rowBytes || bytes.byteLength < (size.height - 1) * rowStride + rowBytes) {
        throw new Error('无法读取相机预览帧');
      }
      const buffer = new Uint8Array(bytes);
      const pixels = new Uint8Array(size.width * size.height);
      for (let row = 0; row < size.height; row++) {
        const offset = row * rowStride;
        if (pixelStride === 1) {
          pixels.set(buffer.subarray(offset, offset + size.width), row * size.width);
        } else {
          for (let column = 0; column < size.width; column++) {
            const source = offset + column * pixelStride;
            pixels[row * size.width + column] = this.rgbaPreview
              ? (77 * buffer[source] + 150 * buffer[source + 1] + 29 * buffer[source + 2]) >> 8
              : buffer[source];
          }
        }
      }
      const packed = new Map<string, number | Uint8Array>();
      packed.set('width', size.width);
      packed.set('height', size.height);
      packed.set('pixels', pixels);
      return packed;
    } finally {
      await frame.release();
    }
  }

  toggleTorch(): boolean {
    if (!this.manager?.isTorchModeSupported(camera.TorchMode.ON)) return false;
    this.manager.setTorchMode(this.torch ? camera.TorchMode.OFF : camera.TorchMode.ON);
    this.torch = !this.torch;
    return this.torch;
  }

  async close(): Promise<void> {
    if (this.torch) {
      try {
        this.manager?.setTorchMode(camera.TorchMode.OFF);
      } catch (_) {}
    }
    await this.session?.stop().catch(() => {});
    await this.session?.release().catch(() => {});
    await this.analysis?.release().catch(() => {});
    await this.preview?.release().catch(() => {});
    await this.input?.close().catch(() => {});
    await this.receiver?.release().catch(() => {});
    try {
      this.texture?.release();
    } catch (_) {}
  }
}
