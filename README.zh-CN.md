<img src="Resources/logo.svg" width="72" height="72" alt="">

# DeskPace

[English](README.md) · **简体中文**

DeskPace 是一款 macOS 菜单栏工具，让你调快四指切换桌面时松手后的动画。滑动时桌面仍然跟手，松手后按你选的速度平滑到位。切到相邻桌面、切入全屏 App 或回弹到原桌面，都使用同一倍率。在最左或最右桌面继续向外划时，由系统按原速回弹。

## 安装与使用

需要 macOS 26 或更高版本，以及已启用四指切换桌面手势的触控板。已在 macOS 27 内建屏上实测。[兼容性与实测结果](docs/motion-results.md)

当前下载包使用临时签名，未经 Apple 公证。macOS 可能阻止 App 首次打开。

1. 从 [GitHub Releases](https://github.com/wawaRou/deskpace/releases/latest) 下载 `DeskPace-<版本号>.zip`，解压后将 `DeskPace.app` 拖入「应用程序」并打开。
2. 点击菜单栏里的 DeskPace 图标，选择「授权辅助功能…」，在系统设置中允许 DeskPace 调节手势。
3. 将滑块从 **1×（系统原速）** 调到想要的速度，最高 **4×**。下一次四指横移就会采用新倍率，设置会自动保存。

安装后，可在菜单栏面板点「检查更新…」获取新版。

[反馈问题](https://github.com/wawaRou/deskpace/issues) · [源码构建与开发](CONTRIBUTING.md) · [MIT 许可证](LICENSE)
