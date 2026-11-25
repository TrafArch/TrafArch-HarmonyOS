# Flutter 鸿蒙宿主

本仓库只支持 HarmonyOS。根目录的 `build-profile.json5` 注册 `entry/`，这是唯一原生宿主。默认入口 `lib/main.dart` 经 `HarmonyApp` 把 `AppDependencies` 注入 `GalleryApp(liveApp:)`，由 `_GalleryLiveRead` 加载安卓当前 2.x 实卡界面；不走预览开关、不加载样例，也不初始化第三方分析。`lib/main_gallery.dart` 仅供 2.x 样例预览，不是发布入口。

## 本轮接入

- 鸿蒙宿主实现原有 NFC MethodChannel、应用私有目录以及 HTTPS 外部链接。NFC 处理的是发现、连接、收发与关闭；复用 Dart 的只读卡片协议，不在 ArkTS 维护第二套解析器。关闭超时不会放行下一次连接。`transit_card_analyzer/nfc_status` EventChannel 监听系统 NFC 开关，关闭时立即退出等待并提示开启，重新开启后恢复读卡入口。
- 2.x 首页、行程、专家与卡包共用 `_GalleryLiveRead` 的同一份实卡投影；专家页按安卓最新 2.x 结构展示逐应用探测、信息获取、交通数据解析、符合性与原始数据，交通应用信息、0x1A／0x1E 过程记录、交易明细和 CU 字段均来自本次读取。支持保存、重命名、删除、冲突策略、导入导出及历史批次浏览；双标卡 TU 行程、苏州逐应用 PIN、青岛 CU 配对、岭南通／深圳通本地钱包均按最新解析链路展示。
- 首页「扫码」进入真实乘车码解析页。相机使用 Camera Kit，首次扫描时请求相机权限；预览优先使用 NV21，也支持模拟器提供的 RGBA_8888。相册使用系统单选器，不申请全量相册权限。两条路径均在本地提取二维码原始字节，复用 Dart 的 JT/T 1179 解析器。
- 应用不接入 Google 服务或第三方使用分析 SDK，不注册分析通道；法律同意页与设置页均没有分析开关，2.x 实卡入口首帧直接进入业务界面，不显示 DEBUG 加载页。
- 设置页接入真实读卡数据：可修改已存在记录的处理策略、上海交通卡透支显示、震动偏好、运行日志，打开诊断日志管理器，并导入／导出卡片 JSON 备份。系统动态配色可用时莫奈跟随系统，否则回退默认靛蓝。设置中的知识库使用 2.x 两级 IA、吸顶搜索、数据概况与城市线路详情，展示当前已校验的 TU／CU 参考库，不再跳转旧版设置页面。
- 日志与卡片备份通过鸿蒙文件选择器保存到用户选择的位置，恢复时选择 TrafArch 导出的 JSON 文件。文件访问使用选择器授予的权限。
- 2.x 设置的内联「关于 TrafArch」在配置更新清单后提供手动检查；正式入口启动时只检查并提示一次。读卡时间在平台边界统一从原生 UTC 转为设备本地时间，深圳通优先展示 PAY.SZT 已观察到的本地钱包余额。
- 交通联合与岭南通或深圳通本地应用同时确认时，卡面按交通联合在上、本地品牌在下的双标排列；单标本地卡只显示对应的岭南通／深圳通 PNG。已保存卡片的品牌依据稳定卡型和冻结应用证据恢复。
- 首页读卡条接通读卡器真实百分比；未发现卡片时仍使用循环动画。更换卡面半模态延伸到系统导航栏下方，交互内容继续避让手势区。首页／预览卡名 20sp、卡包列表卡名 18sp、详情卡名 24sp。
- 自定义卡面的图片与两处裁切参数、Monet seed 按卡片写入应用私有目录并在重启后恢复；卡片排序、页面恢复与现场读取恢复沿用 2.x 实卡适配器。

## Windows 构建

使用 DevEco Studio 26 / API 26，以及 [CPF-Flutter SDK](https://gitcode.com/CPF-Flutter/flutter_flutter) 提交 `c5880c605eb77e82d5585cef24d7b4228d84a84d`。浅克隆需要同时获取祖先标签 `3.47.7+ohos-0.0.1-canary`，否则 Flutter 可能报告 `0.0.0-unknown`，无法解析依赖。Windows 下 Hvigor 项目缓存需要创建目录链接；若报 `EPERM ... symlink`，请在允许创建符号链接的环境运行（例如启用 Windows 开发人员模式）。

```powershell
.\dev\harmony\build_hap.ps1 -FlutterRoot 'D:\usually\flutter-ohos-c5880c6'
```

脚本从根目录调用 Hvigor 构建 `entry`，不再复制项目。它把本地构建依赖放在忽略目录，不修改共享 Pub 缓存或依赖锁文件。SQLite 源码固定为 3.54.0 并核对 SHA-256；OHOS NDK 分别生成 `arm64-v8a` 和 `x86_64` 库，避免选到依赖 GLIBC 的 Linux 预编译库。默认 HAP 同时包含两种 ABI，脚本会校验两种架构的 ELF。配置签名后，安装使用 `entry/build/default/outputs/default/entry-default-signed.hap`，不要选旧的 ARM64 单架构包或 `build/harmony/TrafArch-ohos-arm64-x64-debug-unsigned.hap`。

每次通过该脚本成功生成并校验 HAP 后，`AppScope/app.json5` 的 `versionCode` 自动递增，供下一次构建使用；当前 HAP 保留本次构建号。`-PrepareOnly`、依赖准备失败或 HAP 构建失败均不消耗构建号。脚本会同步 `.flutter-harmony.properties`，使后续 Hvigor／DevEco 构建也使用递增后的号码。

版本文件更新逻辑可用 `pwsh -NoProfile -File .\dev\harmony\test_version.ps1` 单独检查；该测试只操作临时副本，不改变应用构建号。

要用 DevEco 的构建按钮，先将上面的构建命令加上 `-PrepareOnly`，然后用 **File → Open** 打开仓库根目录。此后可以在同一目录运行 `ohpm install --all`，在 DevEco 选择 `entry` 构建。若手动运行 `flutter pub get` 刷新了包配置，再运行一次 `-PrepareOnly` 恢复 OHOS SQLite 构建配置。

发布版本号与构建号在 `AppScope/app.json5` 的 `versionName` 和 `versionCode` 中设置。关于页、日志及更新检查读取已安装 HAP 的版本信息。

签名统一使用 TrafArch 发布证书。`build-profile.json5` 仅保留名为 `default` 的发布签名配置，产品也固定引用 `default`；证书为 `TrafArch-appgallery-release.cer`，Profile 为 `TrafArch_发布Release.p7b`，证书 SHA-256 为 `0C:08:06:B6:F2:DF:CF:8B:3D:4E:CF:44:15:BB:59:A8:49:26:33:31:AE:90:48:28:C5:F0:01:61:2E:87:24:73`。调试、发布与 DevEco 构建沿用同一条配置。

Windows 桌面测试使用上游 Flutter：先用该 SDK 运行 `flutter pub get --enforce-lockfile`，再运行 `flutter test --no-pub`。不要混用上游 Flutter 的测试进程和 OHOS SDK 生成的包配置；回到 DevEco 构建前重新执行 `-PrepareOnly`。

设备验收仍需覆盖：首次同意、实际贴卡、取消和掉卡、切后台、连续换卡、离线站名、重启后打开卡包，以及目标机型上的 FeliCa／八达通。

扫码真机验收：首页打开「扫码」，首次允许相机权限后，用相机扫描一张 JT/T 1179 乘车码，再从相册导入同一二维码，确认解析字段和原始 HEX 一致。另需验证拒绝权限后可返回相册导入、相册取消不清除上一次结果、退出扫码或切后台后相机释放，以及回前台后可以继续扫描。
