<img src="Resources/logo.svg" width="72" height="72" alt="">

# DeskPace

[English](README.md) · 简体中文

DeskPace 是一款 macOS 菜单栏工具。四指切换桌面时，桌面照常跟着手指移动。松手后，你可以让剩下的动画以最高 4 倍速走完。切到全屏 App、划到一半松手回到原桌面，也可以调速。

## 安装

以下说明适用于 v1.0.0 及后续版本。如果发布页还没有 v1.0.0，可以先[从源码构建](CONTRIBUTING.md#从源码运行)。

需要 macOS 26 或更高版本，并在触控板设置中启用四指切换桌面的手势。

1. 在 [GitHub Releases](https://github.com/wawaRou/deskpace/releases/latest) 选择 v1.0.0 或更高版本，下载该版本的 ZIP，解压后将 `DeskPace.app` 拖入「应用程序」。
2. 打开 DeskPace。DeskPace 使用项目自己的证书签名，而不是 Apple Developer ID 证书，也未经 Apple 公证。如果 macOS 提示无法验证 DeskPace，打开「系统设置 → 隐私与安全性」（macOS 27 上为「隐私与安全」），在 DeskPace 的提示旁点「仍要打开」并确认。
3. 菜单栏会弹出 DeskPace 面板。点「授权辅助功能…」，在「系统设置 → 隐私与安全性 → 辅助功能」中启用 DeskPace。macOS 27 上这一页叫「隐私与安全 → 设备控制和数据访问」。几秒内面板就会识别到授权。

## 调整速度

拖动面板里的滑块，选择 1×（系统原速）到 4× 之间的倍率。下一次划动就会生效，退出后仍会保留。

点「恢复原速」可以回到 1×。

## 设置

点菜单栏面板里的「设置…」，可以：

- 切换简体中文或 English。系统语言是其中之一时，DeskPace 默认跟随系统，否则使用英文。
- 开启「登录时启动」。之后每次登录这台 Mac，DeskPace 都会自动出现在菜单栏，沿用上次保存的倍率。
- 立即检查更新，或开启「自动检查更新」。

## 更新

更新包使用同一张证书签名，更新后辅助功能授权仍然有效。

从 v0.1.6 或更早版本更新时，App 的身份会变化，需要再授权一次。如果系统设置里已启用 DeskPace，面板却仍在等待授权，请在辅助功能列表中用「−」移除所有 DeskPace 条目。然后再点一次面板里的授权按钮，重新开启 DeskPace。如果列表里没有重新出现 DeskPace，点「+」把它加回来。v0.1.6 之前的版本无法自动更新，请手动下载一次新版。

## 隐私

DeskPace 需要辅助功能权限，才能暂扣并调整四指横移的手势事件。它不读取键盘或其他输入。只有检查更新时才会联网访问 GitHub，不收集任何数据。倍率和语言只保存在本机。

## 已知限制

- 目前在 Apple 芯片 Mac 的内建屏上、macOS 27.2.1 中实测过。Intel Mac、macOS 26 和外接显示器尚未真机测试。详见[实测记录](docs/motion-results.md)。
- 在第一个或最后一个桌面向外划时，回弹保持系统原速。
- DeskPace 依赖 macOS 私有接口。系统更新移除这些接口后，划动会恢复系统原速，面板会显示原因。接口的其他改动可能让 DeskPace 工作异常，直到 DeskPace 发布更新。遇到这种情况，请先退出 DeskPace，再[反馈问题](https://github.com/wawaRou/deskpace/issues)。

## 卸载

在设置中关闭「登录时启动」，点面板里的「退出」，再把 DeskPace 移到废纸篓。然后在系统设置的辅助功能列表中移除 DeskPace。如需删除保存的设置，在终端运行 `defaults delete dev.wawarou.deskpace`。如果用过 v0.1.6 或更早版本，再运行 `defaults delete dev.switchdesktop.prototype`。

[反馈问题](https://github.com/wawaRou/deskpace/issues) · [源码构建与开发](CONTRIBUTING.md) · [MIT 许可证](LICENSE) · 更新功能使用 [Sparkle](https://sparkle-project.org)（MIT）
