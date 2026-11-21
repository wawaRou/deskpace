# 参与 DeskPace 开发

手势行为使用[项目术语](GLOSSARY.md)。改动跟手阶段、收尾曲线或兼容策略前，先读[保留原生四指横移](docs/adr/0001-preserve-native-swipe-motion.md)和[按 macOS 大版本验证](docs/adr/0002-macos-version-compatibility.md)。

## 从源码运行

安装 Xcode Command Line Tools，使用支持 macOS 26 的 SDK，在项目根目录执行以下命令。如果菜单栏里已经运行了另一份 DeskPace，先从面板退出。

```sh
./build.sh
open build/DeskPace.app
```

默认构建使用临时签名。经常在同一台 Mac 上调试时，可以配置固定签名身份，让系统在重新构建后继续识别辅助功能授权。[本地签名配置](docs/releasing.md#本地构建与辅助功能授权)

## 修改手势行为

- 在 `SwipeEngine` 处理一次手势从开始、抬手到交还的顺序。每个被暂存的抬手事件只交还一次，连续回切时要先交还上一次手势。
- 在 `SwipePayload` 同步修改 Quartz 事件与触控板数据，在 `NativeSpaces` 读取桌面空间。保留测试输入的独立构造方式，让探针能发现事件编码错误。
- `DisplayFeedback` 根据同一显示器已确认的原速收尾决定何时重试。它只需要观测结果，可用离线样本检查。桌面是否实际移动、目标窗口何时收到点击，由真机探针检查。

## 验证改动

在项目根目录运行以下命令。拉取请求也会运行这两项检查。

```sh
./Tests/verify-motion.sh --offline
./build.sh
```

修复回归时，用能在旧行为上失败的最小用例描述问题。涉及手势事件、位移判定或动画倍率的改动，还需按[真机验证方法](docs/motion-verification.md)测试，并记录系统、显示器和实测场景。

安装步骤、系统要求或面板操作有变时，同步更新中英文 README。验收条件写入[手势验证方法](docs/motion-verification.md)，带系统版本和显示器配置的测量数据写入[实测记录](docs/motion-results.md)。准备分发新版本时，按[发布指南](docs/releasing.md)打包并校验附件。
