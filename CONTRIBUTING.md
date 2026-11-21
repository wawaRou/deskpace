# 参与 DeskPace 开发

## 从源码运行

在 Mac 上安装 Xcode Command Line Tools，使用支持 macOS 26 的 SDK。若 DeskPace 已经运行，先在菜单栏面板点「退出」，再从仓库根目录构建并打开 App。这样可以确保手势由刚构建的 App 处理。首次构建会从 GitHub 下载固定版本的 Sparkle，校验后缓存到 `.build/`。

```sh
./build.sh
open build/DeskPace.app
```

打开面板，按提示授予辅助功能权限。默认构建使用临时签名，每次重新构建都要重新授权。想免去这一步，可以在「钥匙串访问 → 证书助理 → 创建证书」中创建一张「代码签名」类型的自签证书，再按[签名证书](docs/releasing.md#签名证书)一节把它配置给这个仓库。

调试时可以从终端直接运行可执行文件，加 `--trace` 打印手势和状态日志。这样启动时，辅助功能权限算在终端上，需要先给终端授权。

```sh
build/DeskPace.app/Contents/MacOS/DeskPace --trace
```

## 修改代码

`Sources/` 根目录下是手势引擎，测试程序会一起编译。`Sources/App/` 下是菜单栏 App，依赖 SwiftUI 和 Sparkle，不进入测试程序。

| 改动 | 相关文件 |
| --- | --- |
| 跟手、松手、连续划动时的事件顺序 | [SwipeEngine.swift](Sources/SwipeEngine.swift) |
| 同步修改 Quartz 事件与其中的触控板数据 | [SwipePayload.swift](Sources/SwipePayload.swift) |
| 读取显示器上的空间排列、当前空间和位置 | [NativeSpaces.swift](Sources/NativeSpaces.swift) |
| 计算松手后每一帧的位移 | [TailCurve.swift](Sources/TailCurve.swift) |
| 某块显示器失去位移反馈后，决定何时重试加速 | [DisplayFeedback.swift](Sources/DisplayFeedback.swift) |
| 倍率、语言、授权、登录项和更新 | [MenuModel.swift](Sources/App/MenuModel.swift) |
| 菜单栏面板和设置窗口 | [Panels.swift](Sources/App/Panels.swift)、[main.swift](Sources/App/main.swift) |
| 状态提示的文案。面板和窗口里的文字写在 Panels.swift、main.swift 中，每条都要同时写中英文 | [AppLanguage.swift](Sources/App/AppLanguage.swift) |

测试程序不复用 App 的事件编码，而是用自己的一份字段编号构造手势输入。修改事件字段时保留这种独立性，否则 App 和测试会带着同一个错误通过。[测试手势的构造](Tests/GestureFixture.swift)

## 提交前验证

提交前可以在本机运行离线测试并构建 App。GitHub Actions 会对拉取请求和推送到 `main` 的提交执行同样的检查。

```sh
./Tests/verify-motion.sh --offline
./build.sh
```

修复手势问题时，先用测试复现问题，再用同一个用例验证修复。改动事件顺序、桌面位置判断或动画倍率后，再用真机复测对应的操作。[测试命令与通过条件](docs/motion-verification.md)

## 文档放在哪里

| 要记录的内容 | 文档 |
| --- | --- |
| 安装、授权、面板操作 | [英文 README](README.md) 和[中文 README](README.zh-CN.md)，两份同步更新。改了界面文字，也要同步其中的按钮名 |
| 手势和计时指标的含义 | [术语表](GLOSSARY.md) |
| 为什么保留系统动画，为什么使用私有接口 | [手势设计决定](docs/adr/0001-preserve-native-swipe-motion.md)、[兼容性决定](docs/adr/0002-macos-version-compatibility.md) |
| 怎样复测、怎样判断通过 | [手势验证方法](docs/motion-verification.md) |
| 哪个版本在哪台设备上测过、实际测到了什么 | [手势实测记录](docs/motion-results.md) |
| 配置签名、打包更新、发布附件 | [签名与发布](docs/releasing.md) |
