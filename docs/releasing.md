# 签名与发布

macOS 用 App 的代码签名识别辅助功能授权。Sparkle 用 App 内置的 Ed25519 公钥验证更新清单和安装包。[Apple 代码签名说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) · [Sparkle 更新发布说明](https://sparkle-project.org/documentation/publishing/)

## 签名证书

项目没有 Apple Developer ID，发布包和本机调试都使用同一张自签代码签名证书。用这张证书签名后，App 的指定要求是「Bundle ID 为 `dev.wawarou.deskpace`，且叶证书为这张证书」。只要继续用它签名，用户更新后无需重新授权辅助功能。临时签名的指定要求是代码哈希，每次构建都会变，所以不要用临时签名发布。

下面的命令列出本机可用的签名身份。用证书的 40 位指纹替换第二行的占位文字，再运行构建脚本。

```sh
security find-identity -v -p codesigning
git config --local deskpace.signingIdentity '替换为证书指纹'
./build.sh
```

`build.sh` 优先读取环境变量 `CODE_SIGN_IDENTITY`，其次读取上述 Git 配置。两者都为空时，使用临时签名。如果 `build/DeskPace.app` 已带固定签名而本次没有配置签名身份，脚本会停止构建，保留原有 App。指定的签名身份不可用时，脚本会在替换 App 前退出。

**备份证书。** 在「钥匙串访问」中把证书连同私钥导出为 `.p12`，用密码保护，存到发布机以外的地方。证书丢失后只能换一张新证书，所有用户更新后都要重新授权一次。打包脚本里固定写着发布证书的指纹，换证书时要同时修改它，并在 Release 说明中提醒用户重新授权。改用 Developer ID 还需要为所有组件加上 `--options runtime --timestamp` 签名，并在打包前完成公证。

## 本地构建与辅助功能授权

临时签名的 App 每次重新构建后，原有授权都会失效。从菜单栏退出 DeskPace，打开 `build/DeskPace.app`，按面板提示授权。如果系统设置里的 DeskPace 已启用，面板仍在等待授权，在权限列表中移除 DeskPace，再添加刚构建的 App。配置了上面的固定证书后，重新构建不再需要授权。

## 准备安装包

1. 在 `Resources/Info.plist` 中更新用户可见的版本号 `CFBundleShortVersionString`，递增构建号 `CFBundleVersion`。Sparkle 用构建号比较版本。提交这次改动。
2. 在持有项目更新私钥和签名证书的 Mac 上运行 `./Scripts/package-update.sh`。脚本先确认工作区没有未提交的改动、配置的证书指纹与脚本里固定的发布证书一致，再从记录的提交导出一份独立源码，调用其中的 `build.sh` 构建包含 arm64 和 x86_64 的 App，并核对 App 的叶证书。随后校验更新地址，读取 GitHub 上的版本标签，确认这个版本号还没有打过标签、构建号大于上一个已发布版本，核对钥匙串与 App 内置公钥，生成 ZIP 和带签名的清单，再用公钥验证 ZIP 签名。最后输出所用的提交。

两个附件位于 `build/releases/v<版本号>/`，文件名是 `DeskPace-<版本号>.zip` 和 `appcast.xml`。签名后保留它们的名字和内容。脚本一次移入整个附件目录；同一版本已有目录时会停止，避免重新签名的 ZIP 和已上传的附件混用。[打包脚本](../Scripts/package-update.sh)

普通源码构建只需仓库里的更新公钥。更换发布机时，迁移代码签名证书及其私钥，并将 Sparkle 更新私钥导入钥匙串。更新私钥的账户名见[打包脚本](../Scripts/package-update.sh)中的 `account`。更新私钥、证书私钥及 GitHub 凭据均应留在发布环境中。

## 发布与验收

1. 把脚本输出的提交推送到 `main`，再在 `wawaRou/deskpace` 为它创建 GitHub Release 草稿，标签填 `v<版本号>`。
2. 上传 ZIP 和 `appcast.xml`，核对版本、文件名和大小。在 Release 说明中写明签名方式和是否需要重新授权，与两份 README 的「安装」「更新」两节保持一致。
3. 发布正式 Release 并设为 **Latest**。App 从 Latest 获取清单，清单中的 ZIP 地址指向具体版本的标签。[App 使用的更新清单地址](https://github.com/wawaRou/deskpace/releases/latest/download/appcast.xml)
4. 在未登录 GitHub 的会话中打开清单，下载它指向的 ZIP。这一步验证用户能匿名取得更新。
5. 首次发布时，从下载的 ZIP 安装 App，确认可以授权并调节倍率。发布更新时，在已安装的 DeskPace 中点「检查更新…」，完成安装后核对版本号、保存的倍率和辅助功能权限。

在终端也可以核对 Latest 对应的标签和附件名。

```sh
gh api repos/wawaRou/deskpace/releases/latest --jq '{tag: .tag_name, assets: [.assets[].name]}'
```
