# 签名与发布

macOS 用 App 的代码签名识别辅助功能授权。Sparkle 用 App 内置的 Ed25519 公钥验证更新清单和安装包。[Apple 代码签名说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) · [Sparkle 更新发布说明](https://sparkle-project.org/documentation/publishing/)

## 本地构建与辅助功能授权

临时签名的 App 重新构建后，macOS 可能再次要求授权。退出旧进程，打开 `build/DeskPace.app` 并按面板提示授权。如果系统设置里的 DeskPace 已启用，面板仍在等待授权，移除旧条目，再添加刚构建的 App。

经常在同一台 Mac 上调试时，可以在 Xcode 的账户设置里创建 Apple Development 证书。下面的命令列出本机可用的签名身份。选一个证书，用它的 40 位指纹替换第二行的占位文字，再运行构建脚本。

```sh
security find-identity -v -p codesigning
git config --local switchdesktop.signingIdentity '替换为证书指纹'
./build.sh
```

`build.sh` 优先读取环境变量 `CODE_SIGN_IDENTITY`，其次读取上述 Git 配置。两者都为空时，使用临时签名。如果已有 App 带有固定签名而本次没有配置签名身份，脚本会停止构建，保留原有 App。指定的身份不可用时，构建失败，旧 App 仍可使用。更换签名团队或证书类型后，重新验证辅助功能授权。

`switchdesktop.signingIdentity` 是项目前身沿用下来的配置名。App 的 Bundle ID 和 Sparkle 使用的钥匙串账户也沿用 `dev.switchdesktop.prototype`。

## 准备安装包

1. 在 `Resources/Info.plist` 中更新用户可见的版本号 `CFBundleShortVersionString`，递增构建号 `CFBundleVersion`。Sparkle 用构建号比较版本。
2. 在项目根目录运行 `./build.sh`。脚本取得固定版本的 Sparkle，构建包含 arm64 和 x86_64 的 App 并校验代码签名。
3. 如果发布公证版，在打包前完成 Developer ID 签名、公证和票据装订。这些步骤需要发布者另行办理。
4. 在持有项目更新私钥的 Mac 上运行 `./Scripts/package-update.sh`。脚本校验 App 签名和更新地址，核对钥匙串与 App 内置公钥，生成 ZIP 和带签名的清单，再用公钥验证 ZIP 签名。

两个附件位于 `build/releases/v<版本号>/`，文件名是 `DeskPace-<版本号>.zip` 和 `appcast.xml`。签名后保留它们的名字和内容。[打包脚本](../Scripts/package-update.sh)

普通源码构建只需仓库里的公钥。更换发布机时，安全迁移钥匙串里的原更新私钥，已安装的 App 才能继续验证新版。更新私钥、证书私钥及 GitHub 凭据均应留在发布环境中。

## 发布与验收

1. 在 `wawaRou/deskpace` 为构建所用的提交创建 GitHub Release 草稿，标签填 `v<版本号>`。
2. 上传 ZIP 和 `appcast.xml`，核对版本、文件名和大小。在安装说明中写明该版本的签名和公证状态。v0.1.6 使用临时签名，未经 Apple 公证。
3. 发布正式 Release 并设为 **Latest**。App 从 Latest 获取清单，清单中的 ZIP 地址指向具体版本的标签。[App 使用的更新清单地址](https://github.com/wawaRou/deskpace/releases/latest/download/appcast.xml)
4. 在未登录 GitHub 的会话中打开清单，下载它指向的 ZIP。这一步验证用户能匿名取得更新。

在终端也可以核对 Latest 对应的标签和附件名。

```sh
gh api repos/wawaRou/deskpace/releases/latest --jq '{tag: .tag_name, assets: [.assets[].name]}'
```

改用 Developer ID 发布时，从最终 ZIP 测试首次安装，再从上一公开版本更新。检查倍率设置和辅助功能授权是否保留，按实测结果更新中英文安装说明。
