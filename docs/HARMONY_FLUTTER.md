# Flutter 鸿蒙宿主

本仓库只支持 HarmonyOS。根目录的 `build-profile.json5` 注册 `entry/`，这是唯一原生宿主。默认入口 `lib/main.dart` 在同意协议后直接加载原版 Flutter 2.x 页面，不走预览开关、不加载样例，也不初始化 Firebase。`lib/main_gallery.dart` 仅供 2.x 样例预览，不是发布入口。

## 本轮接入

- 鸿蒙宿主实现原有 NFC MethodChannel、应用私有目录以及 HTTPS 外部链接。NFC 处理的是发现、连接、收发与关闭；复用 Dart 的只读卡片协议，不在 ArkTS 维护第二套解析器。关闭超时不会放行下一次连接。
- 2.x 首页调用真实业务依赖；专家页按安卓最新 2.x 结构展示信息获取、交通数据解析、符合性与原始数据，交通应用信息、0x1A／0x1E 过程记录、交易明细和 CU 字段均来自本次读取。支持把已识别的卡片保存到原有 Drift 档案。行程和档案详情目前展示原版快照中的交易明细；完整行程投影、其他记录类型和历史批次浏览仍待接入。
- 首页「扫码」进入真实乘车码解析页。相机使用 Camera Kit，首次扫描时请求相机权限；预览优先使用 NV21，也支持模拟器提供的 RGBA_8888。相册使用系统单选器，不申请全量相册权限。两条路径均在本地提取二维码原始字节，复用 Dart 的 JT/T 1179 解析器。
- 设置页接入真实读卡数据：可修改已存在记录的处理策略、上海交通卡透支显示、运行日志，打开诊断日志管理器，并导入／导出卡片 JSON 备份。设置中的知识库使用 2.x 卡片、分段条和展开层级展示本地 TU／CU 参考库，不再跳转旧版设置页面。
- 卡面更换、卡片排序和现场恢复尚未完整接入鸿蒙。不用预览功能冒充实际能力。

## Windows 构建

使用 DevEco Studio 26 / API 26，以及 [CPF-Flutter SDK](https://gitcode.com/CPF-Flutter/flutter_flutter) 提交 `c5880c605eb77e82d5585cef24d7b4228d84a84d`。浅克隆需要同时获取祖先标签 `3.47.7+ohos-0.0.1-canary`，否则 Flutter 可能报告 `0.0.0-unknown`，无法解析依赖。Windows 下 Hvigor 项目缓存需要创建目录链接；若报 `EPERM ... symlink`，请在允许创建符号链接的环境运行（例如启用 Windows 开发人员模式）。

```powershell
.\dev\harmony\build_hap.ps1 -FlutterRoot 'D:\usually\flutter-ohos-c5880c6'
```

脚本从根目录调用 Hvigor 构建 `entry`，不再复制项目。它把本地构建依赖放在忽略目录，不修改共享 Pub 缓存或依赖锁文件。SQLite 源码固定为 3.54.0 并核对 SHA-256；OHOS NDK 分别生成 `arm64-v8a` 和 `x86_64` 库，避免选到依赖 GLIBC 的 Linux 预编译库。默认 HAP 同时包含两种 ABI，脚本会校验两种架构的 ELF。配置签名后，安装使用 `entry/build/default/outputs/default/entry-default-signed.hap`，不要选旧的 ARM64 单架构包或 `build/harmony/TrafArch-ohos-arm64-x64-debug-unsigned.hap`。

要用 DevEco 的构建按钮，先将上面的构建命令加上 `-PrepareOnly`，然后用 **File → Open** 打开仓库根目录。此后可以在同一目录运行 `ohpm install --all`，在 DevEco 选择 `entry` 构建。若手动运行 `flutter pub get` 刷新了包配置，再运行一次 `-PrepareOnly` 恢复 OHOS SQLite 构建配置。

Windows 桌面测试使用上游 Flutter：先用该 SDK 运行 `flutter pub get --enforce-lockfile`，再运行 `flutter test --no-pub`。不要混用上游 Flutter 的测试进程和 OHOS SDK 生成的包配置；回到 DevEco 构建前重新执行 `-PrepareOnly`。

设备验收仍需覆盖：首次同意、实际贴卡、取消和掉卡、切后台、连续换卡、离线站名、重启后打开卡包，以及目标机型上的 FeliCa／八达通。

扫码真机验收：首页打开「扫码」，首次允许相机权限后，用相机扫描一张 JT/T 1179 乘车码，再从相册导入同一二维码，确认解析字段和原始 HEX 一致。另需验证拒绝权限后可返回相册导入、相册取消不清除上一次结果、退出扫码或切后台后相机释放，以及回前台后可以继续扫描。
