---
description: 为 Shawn 的 iPhone 17 Pro 构建全能签专用 IPA，并复核签名身份与系统能力
---

# iPhone 17 Pro 专用自签工作流

## 固定身份

- 设备：iPhone 17 Pro
- UDID：`00008150-001E58CA3E84401C`
- Team ID：`8CAEUC6576`
- Bundle ID：`app.tourmaline5269.brown6028`
- 完整 App ID：`8CAEUC6576.app.tourmaline5269.brown6028`
- 描述文件：`/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/个人/iPhone 17 Pro 证书/描述文件.mobileprovision`

## 执行步骤

1. 先运行项目的 Swift 零警告检查和 Xcode 真机构建，确保两者均成功且 Warning 为 0。
2. 运行：

   ```bash
   Scripts/build-iphone17pro-allsign.sh
   ```

3. 脚本必须先解析描述文件，只有当 App ID 为 `8CAEUC6576.app.tourmaline5269.brown6028` 时才能继续。
4. 将 `dist/` 中新生成的 `Scale-iPhone17Pro-AllSign-*.ipa` 传给 iPhone 17 Pro，在全能签中使用现有证书签名。
5. 全能签中不得修改 Bundle ID，必须保持 `app.tourmaline5269.brown6028`。
6. 取回全能签产出的 IPA 后运行：

   ```bash
   Scripts/verify-iphone17pro-signature.sh "/绝对路径/已签名.ipa"
   ```

7. 只有当以下检查全部通过时才可安装：

   - `CFBundleIdentifier` 为 `app.tourmaline5269.brown6028`；
   - 代码签名的 `application-identifier` 为 `8CAEUC6576.app.tourmaline5269.brown6028`；
   - 嵌入描述文件的 `application-identifier` 与上述值相同；
   - HealthKit Entitlement 为 `true`；
   - `codesign --verify --deep --strict` 通过。

## 已知边界

- 该专用自签版与 `shuhui.scaleapp` 的 7 天签名版是两个系统应用身份，可并存安装。
- 第一次运行专用自签版时，需重新授权 Apple「健康」并重新选择 iCloud 同步文件夹。
- 禁止把 p12 密码、私钥、解密文件或临时 Keychain 写入仓库或日志。
