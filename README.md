<img src="Resources/logo.svg" width="72" height="72" alt="">

# DeskPace

English · [简体中文](README.zh-CN.md)

DeskPace is a macOS menu bar app for four-finger desktop swipes. The desktop follows your fingers as usual. When you lift them, you can have the animation finish up to four times faster. The setting also applies when you swipe to a full-screen app or let a partial swipe return to the starting desktop.

## Install

These instructions apply to v1.0.0 and later. If v1.0.0 is not on the releases page yet, you can [build from source](CONTRIBUTING.md#从源码运行).

You need macOS 26 or later and a trackpad with four-finger desktop switching enabled.

1. Choose v1.0.0 or later on [GitHub Releases](https://github.com/wawaRou/deskpace/releases/latest), download and unzip its DeskPace ZIP, and drag `DeskPace.app` into Applications.
2. Open DeskPace. DeskPace is signed with the project's own certificate rather than an Apple Developer ID, and Apple hasn't notarized it. If macOS says it can't verify DeskPace, open **System Settings → Privacy & Security**, click **Open Anyway** next to the DeskPace message, and confirm.
3. The DeskPace panel opens from the menu bar. Click **Grant Accessibility Access…** and turn on DeskPace in System Settings under **Privacy & Security → Accessibility** (**Privacy & Security → Device Control and Data Access** on macOS 27). The panel picks up the change within a few seconds.

## Set the speed

Move the slider in the panel between 1× (system speed) and 4×. The next swipe uses your setting, and DeskPace keeps it after you quit.

Click **Reset Speed** to return to 1×.

## Settings

Open **Settings…** from the menu bar panel to:

- Switch between English and Simplified Chinese. DeskPace starts in your system language when it is one of these two, and in English otherwise.
- Turn on **Launch at Login** to start DeskPace with your saved speed whenever you log in to this Mac.
- Check for updates now, or turn on **Check for Updates Automatically**.

## Update

Updates are signed with the same certificate, so DeskPace keeps its Accessibility access.

Updating from v0.1.6 or earlier changes the app's identity, so you need to grant access once more. If the panel keeps waiting although DeskPace is already turned on, remove every DeskPace entry from the Accessibility list with **−**. Then click the access button in the panel again and turn DeskPace on. If DeskPace doesn't reappear in the list, add it with **+**. Versions before v0.1.6 can't update themselves, so download the new version once by hand.

## Privacy

DeskPace needs Accessibility access to hold and adjust the events of horizontal four-finger swipes. It doesn't read your keyboard or other input. It connects to the internet only to check for updates on GitHub, and it collects no data. Your speed and language are stored only on this Mac.

## Known limitations

- DeskPace has been tested on macOS 27.2.1 with the built-in display of an Apple silicon Mac. Intel Macs, macOS 26 and external displays haven't been tested on real hardware. See the [test results (in Chinese)](docs/motion-results.md).
- When you swipe outward past your first or last desktop, the bounce stays at system speed.
- DeskPace relies on private macOS interfaces. If a macOS update removes them, swipes return to system speed and the panel shows why. Other changes to them can make DeskPace misbehave until a DeskPace update follows. If that happens, quit DeskPace and [report an issue](https://github.com/wawaRou/deskpace/issues).

## Uninstall

In Settings, turn off **Launch at Login**. Click **Quit** in the panel and move DeskPace to the Trash. Then remove DeskPace from the Accessibility list in System Settings. To delete its saved settings, run `defaults delete dev.wawarou.deskpace` in Terminal. If you once used v0.1.6 or earlier, also run `defaults delete dev.switchdesktop.prototype`.

[Report an issue](https://github.com/wawaRou/deskpace/issues) · [Build and contribute (in Chinese)](CONTRIBUTING.md) · [MIT license](LICENSE) · Updates use [Sparkle](https://sparkle-project.org) (MIT)
