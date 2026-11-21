# 签名与发布

DeskPace 使用两种签名。macOS 通过 App 的代码签名识别辅助功能授权，Sparkle 通过 App 内置的 Ed25519 公钥验证更新清单和安装包。给更新包签名后，App 本身仍保留打包前的代码签名身份。

## 本地构建与辅助功能授权

从临时签名迁移到固定身份时，可在 Xcode 的账户设置里创建 Apple Development 证书。在项目目录列出本机可用的签名身份，并将所选证书的 40 位指纹保存到当前仓库的本地 Git 配置：

```sh
security find-identity -v -p codesigning
git config --local switchdesktop.signingIdentity '替换为证书指纹'
./build.sh
```

临时签名的 App 重新构建后，macOS 可能要求重新授予辅助功能权限。退出旧进程，打开 `build/DeskPace.app` 并授权。若系统显示旧条目已开启，但面板仍提示等待授权，在系统隐私设置里移除 DeskPace 的旧条目，再添加刚构建的 App。此后用同一身份构建，以便 macOS 继续识别它。更换签名团队或证书类型时需要重新验证授权。[Apple 代码签名身份说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

构建脚本优先使用环境变量 `CODE_SIGN_IDENTITY`，其次读取上述 Git 配置；两者均未指定时使用临时签名。如果已有产物使用固定签名，脚本会阻止因遗漏身份配置而用临时签名覆盖它。指定的签名身份不可用时，构建失败，原产物保留。

`dev.switchdesktop.prototype` 是 DeskPace 沿用的 Bundle ID，构建脚本、手势测试和 Sparkle 钥匙串账户仍引用它。`switchdesktop.signingIdentity` 同样沿用更名前的配置名。

## 打包更新

1. 在 `Resources/Info.plist` 中更新展示版本 `CFBundleShortVersionString`，并递增 `CFBundleVersion`。Sparkle 根据后者判断是否有更新。
2. 运行 `./build.sh`。脚本从 `Scripts/prepare-sparkle.sh` 获取固定版本的 Sparkle，构建并验证通用 App。若要发布 Developer ID 公证版，需要另行完成符合公证要求的签名、公证和票据装订，再对最终 App 打包。现有构建和打包脚本均未自动办理公证。
3. 在持有项目更新私钥的发布机上运行 `./Scripts/package-update.sh`。脚本校验已构建 App 的代码签名和更新地址，核对钥匙串账户的公钥与 App 内置公钥，生成完整 ZIP 和签名清单，并用公钥复核 ZIP 签名。
4. 从 `build/releases/v<版本号>/` 取出 `DeskPace-<版本号>.zip` 和 `appcast.xml`。清单中的下载地址已包含标签 `v<版本号>` 和 ZIP 文件名。签名后保留两份文件的原始内容及文件名。

普通源码构建只需要仓库里的公钥。发布时使用的 Sparkle 私钥保存在钥匙串中，换机时需要安全迁移原密钥，以便已安装的 App 能继续验证更新。请勿将私钥、证书私钥或 GitHub 凭据放入源码、安装包或 Release 附件。[Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/)

## 发布到 GitHub Releases

在 `wawaRou/deskpace` 为构建所用提交创建 Release 草稿，标签使用 `v<版本号>`。上传两份附件，核对版本、文件名和大小后发布为正式 Release，并设为 **Latest**。仅推送 Git 标签不会更新 App 使用的清单。

v0.1.6 的公开安装包使用临时签名，未经 Apple 公证。在 Release 安装说明中标明该版本实际使用的签名身份和公证状态。

取得 Developer ID Application 证书后，再切换公开版的代码签名身份。届时从最终 ZIP 解压测试首次安装，并从上一公开版本测试更新、倍率设置和辅助功能授权；根据实测结果同步更新安装说明。

App 固定读取 [Latest Release 的 appcast.xml](https://github.com/wawaRou/deskpace/releases/latest/download/appcast.xml)。这个地址随 Latest 移动，清单里的 ZIP 地址则始终指向生成清单时的标签。可在有仓库权限的环境用下面的只读命令核对 GitHub 当前返回的 Latest 与附件：

```sh
gh api repos/wawaRou/deskpace/releases/latest --jq '{tag: .tag_name, assets: [.assets[].name]}'
```

发布后，用未登录 GitHub 的会话打开 Latest 的清单地址，再下载清单指向的 ZIP，确认 DeskPace 的匿名更新请求也能取得这两份附件。
