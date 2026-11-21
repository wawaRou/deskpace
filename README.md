<img src="Resources/logo.svg" width="72" height="72" alt="">

# DeskPace

**English** · [简体中文](README.zh-CN.md)

DeskPace is a macOS menu bar app that speeds up the last part of a four-finger desktop swipe. The desktop follows your fingers as usual. Once you lift them, it glides into place at the speed you choose. The same setting applies when you switch desktops, swipe to a full-screen app, or let a partial swipe spring back.

## Getting started

Requires macOS 26 or later and a trackpad configured to switch desktops with four fingers. DeskPace has been tested on macOS 27 with a built-in display. [Compatibility and test results (in Chinese)](docs/motion-verification.md)

The current download uses an ad hoc signature and has not been notarized by Apple. macOS may block the app on first launch.

1. Download `DeskPace-<version>.zip` from [GitHub Releases](https://github.com/wawaRou/deskpace/releases/latest). Unzip it, drag `DeskPace.app` into Applications, and open it.
2. Click the DeskPace menu bar icon, choose **授权辅助功能…** (Grant Accessibility Access), and allow DeskPace in System Settings.
3. Set the slider anywhere from **1×** (system speed) to **4×**. Your next swipe uses the new speed, and DeskPace remembers your setting.

If the display stops reporting movement, macOS finishes the swipe at system speed. DeskPace retries your selected speed once it sees native swipes settle on that display.

To update, choose **检查更新…** (Check for Updates) in the menu bar panel.

## Build from source

With the Xcode Command Line Tools installed and an SDK that supports macOS 26, run these commands from the project root:

```sh
./build.sh
open build/DeskPace.app
```

[Keeping Accessibility access across builds (in Chinese)](docs/releasing.md#本地构建与辅助功能授权) · [Report an issue](https://github.com/wawaRou/deskpace/issues) · [Contributing (in Chinese)](CONTRIBUTING.md) · [MIT License](LICENSE)
