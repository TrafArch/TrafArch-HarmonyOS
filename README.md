# TrafArch for HarmonyOS

本仓库只构建 HarmonyOS。仓库根目录同时是 DevEco 工程和 Flutter 项目；原生宿主是 `entry/`，默认 Dart 入口 `lib/main.dart` 直接启动原版 Flutter 2.x 界面。

在仓库根目录用 PowerShell 构建：

```powershell
.\dev\harmony\build_hap.ps1 -FlutterRoot 'D:\usually\flutter-ohos-c5880c6'
```

默认包同时支持 ARM64 真机和 x86_64 模拟器。安装使用 `entry/build/default/outputs/default/entry-default-signed.hap`；未签名验证包位于 `build/harmony/TrafArch-ohos-arm64-x64-debug-unsigned.hap`。

也可以先给上面的命令加 `-PrepareOnly`，然后在 DevEco 直接打开仓库根目录并构建 `entry`。`ohpm install --all` 同样在仓库根目录运行。不再需要打开或维护构建副本。

工具链、SQLite 和设备验收说明见 [鸿蒙构建文档](docs/HARMONY_FLUTTER.md)。
