# 编出「Photo Pull」版 Erosion

改动（3 处，已在源码里）：

| 文件 | 改了什么 |
|---|---|
| `Erosion/Exploits/WorseQuerySwift.swift` | `grantAccess` 遇到 `-255` 时用 `create_dir = true` 重试，跳过 `worse_query` 里的 `lstat` 预检 —— 这就是 `/var/mobile/Media/...` 一直 `-255` 的根因 |
| `Erosion/Tweaks/Other/PhotoPullView.swift` | 新页面：直接对 `DCIM` / `PhotoData` 调 `worse_query`，把文件复制进 App 的 `Documents/Pulled` |
| `Erosion/Tweaks/TweaksView.swift` | System 分组里加了一个 `Photo Pull` 入口 |

> 工程用的是 `PBXFileSystemSynchronizedRootGroup`（Xcode 26 的文件夹同步），所以新加的 `.swift` 放进去就自动参与编译，**不用动 project.pbxproj**。

## 为什么不能在这台 Windows 上编

- 项目 `IPHONEOS_DEPLOYMENT_TARGET = 26.0`，工程文件里引用了 `iPhoneOS27.0.sdk`
- 编译要 Xcode 26 + iOS 27 SDK + arm64e 工具链，Windows 上没有
- Swift for Windows 能编 Windows 程序，但编不了 Mach-O/iOS，也没有签名链

## 路线 A：有 Mac（5 分钟）

```bash
git clone <你的仓库> && cd Erosion
xcodebuild -project Erosion.xcodeproj -target Erosion -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS=""

mkdir Payload && cp -R build/Build/Products/Release-iphoneos/Erosion.app Payload/
zip -qry Erosion-unsigned.ipa Payload
```

把 `Erosion-unsigned.ipa` 拷回 Windows，继续下面的签名步骤。

## 路线 B：GitHub Actions（没 Mac 时）

仓库里已经有 [`.github/workflows/build.yml`](.github/workflows/build.yml)，推上去就能编：

```bash
git init && git add . && git commit -m "photo pull"
git branch -M main
git remote add origin https://github.com/<你>/<仓库>.git
git push -u origin main
```

然后 GitHub → Actions → `build-unsigned-ipa` → Run workflow，跑完在 Artifacts 里下 `Erosion-unsigned-ipa`。

注意 runner 要选带 Xcode 26 的（`macos-26`）；只有 `macos-15` 的话第一步得 `xcode-select` 到 Xcode 26，且必须有 iOS 27 SDK，否则会报 `iPhoneOS27.0.sdk not found`。

## 签名 + 安装（回到这台 Windows）

```powershell
cd C:\Users\kelvi\Desktop\Erosion-build
python sign_install.py `
  --p12 "C:\Users\kelvi\Desktop\证书\证书文件.p12" --password 1 `
  --profile "C:\Users\kelvi\Desktop\证书\描述文件.mobileprovision" `
  --ipa .\Erosion-unsigned.ipa
```

装完打开 app → Tweaks → **Photo Pull** → 点 `DCIM（全部照片/视频）`。

## 拉数据（不用分享面板）

文件复制进 App 自己的 `Documents/Pulled` 之后，电脑端直接拿：

```powershell
python -m pymobiledevice3 apps pull com.nuownqyyy688.ct12664 /Documents/Pulled .\pulled
```

这样整条链是：**Erosion 的 worse_query 拿到 Media 的 sandbox extension → 自己在设备上复制 → AFC 只负责搬 App 容器**。相册数据确实是被 exploit 读出来的，不是主机直连媒体目录。

## 失败时怎么读日志

App 的 Home 页日志会打：

```
(pl) DCIM 子目录: ["100APPLE", "101APPLE", ...]
(pl) grant failed /var/mobile/Media/DCIM/100APPLE: -5
(pl) copy failed /var/mobile/Media/DCIM/100APPLE/IMG_0001.HEIC: ...
```

- `-5` = containermanagerd 拒了（这版可能把 Media 单独加固了）
- `grant failed: -1` = app group 没解析出来
- `copy failed` 但 grant 是正的 = extension 只覆盖到目录本身、不递归，需要改成逐文件 grant（把 `pullDCIM` 里的 `rawGrant(sub)` 换成对每个文件 grant）
