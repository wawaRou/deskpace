# 参与 DeskPace 开发

手势行为使用[项目术语](GLOSSARY.md)。改动跟手阶段、收尾曲线或兼容策略前，先读[保留原生四指横移](docs/adr/0001-preserve-native-swipe-motion.md)和[按 macOS 大版本验证](docs/adr/0002-macos-version-compatibility.md)。

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

安装步骤或用户可见行为有变时，同步更新英文与中文 README。验收方法放在真机验证文档，签名和分发步骤放在[发布文档](docs/releasing.md)。
