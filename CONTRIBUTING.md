# 参与 DeskPace 开发

## 从源码运行

在 Mac 上安装 Xcode Command Line Tools，使用支持 macOS 26 的 SDK。若 DeskPace 已经运行，先在菜单栏面板点「退出」。然后在仓库根目录构建并打开 App。

```sh
./build.sh
open build/DeskPace.app
```

打开面板，按提示授予辅助功能权限。默认构建使用临时签名。如果每次重新构建都要授权，可以给这个仓库配置固定签名身份。[本地构建与辅助功能授权](docs/releasing.md#本地构建与辅助功能授权)

## 修改手势代码

| 改动 | 相关文件 |
| --- | --- |
| 跟手、松手、连续划动时的事件顺序 | [SwipeEngine.swift](Sources/SwipeEngine.swift) |
| 同步修改 Quartz 事件与其中的触控板数据 | [SwipePayload.swift](Sources/SwipePayload.swift) |
| 读取显示器上的空间排列、当前空间和位置 | [NativeSpaces.swift](Sources/NativeSpaces.swift) |
| 计算松手后每一帧的位移 | [TailCurve.swift](Sources/TailCurve.swift) |
| 某块显示器失去位移反馈后，决定何时重试加速 | [DisplayFeedback.swift](Sources/DisplayFeedback.swift) |

测试程序独立构造手势输入。修改事件编码时，保留这条独立的测试路径，否则 App 和测试可能把同一个字段写错。[测试手势的构造](Tests/GestureFixture.swift)

## 提交前验证

提交前可以在本机运行离线测试并构建 App。GitHub Actions 会对拉取请求和推送到 `main` 的提交执行同样的检查。

```sh
./Tests/verify-motion.sh --offline
./build.sh
```

修复手势问题时，选一个在旧实现上能失败的用例。改动事件顺序、桌面位置判断或动画倍率后，再用真机复测对应的操作。[测试命令与通过条件](docs/motion-verification.md)

## 文档放在哪里

| 要记录的内容 | 文档 |
| --- | --- |
| 安装、授权、面板操作 | [英文 README](README.md) 和[中文 README](README.zh-CN.md)，两份同步更新 |
| 手势和计时指标的含义 | [术语表](GLOSSARY.md) |
| 为什么保留系统动画，为什么使用私有接口 | [手势设计决定](docs/adr/0001-preserve-native-swipe-motion.md)、[兼容性决定](docs/adr/0002-macos-version-compatibility.md) |
| 怎样复测、怎样判断通过 | [手势验证方法](docs/motion-verification.md) |
| 哪个版本在哪台设备上测过、实际测到了什么 | [手势实测记录](docs/motion-results.md) |
| 配置签名、打包更新、发布附件 | [签名与发布](docs/releasing.md) |
