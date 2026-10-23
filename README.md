# QFClash

个人自维护的 Clash 客户端，基于开源项目 [FlClash](https://github.com/chen08209/FlClash)（作者 chen08209）二次构建：自有签名、自有仓库发布、导入订阅自动选最快节点。订阅请自行导入，本仓库不预置任何订阅。

## 下载（按平台分开，不要下错）

发布列表：https://github.com/a718983610-sys/FlClash/releases
每个版本按平台拆成两条发布，标签前缀不同；App 内检查更新也只认本平台的那条，不会串台。

### 安卓版

- 找标签 **`android-v` 开头**的发布（如 `android-v0.9.1`，标题「QFClash 安卓版」）
- 下载 **`QFClash-Android-v<版本号>.apk`**，手机上直接安装；新版同签名覆盖安装，数据不丢

### Windows版

- 找标签 **`windows-v` 开头**的发布（如 `windows-v0.9.1`，标题「QFClash Windows版」）
- **`QFClash-Windows-v<版本号>.exe`**：安装包（推荐，会装好后台服务，TUN 模式要用）
- **`QFClash-Windows-v<版本号>.zip`**：便携版，解压即用
- exe 未做代码签名，首次运行 Windows 会提示「未知发布者」，点「仍要运行」即可

## 自维护出新版（三步）

1. 在 GitHub fork 页点 **Sync fork** 同步上游更新；
2. 到 **Actions** 页分别运行 `build-qingfeng-android` 与 `build-qingfeng-windows`；
3. 构建完，新版本自动出现在 **Releases**（安卓、Windows 各一条），手机/电脑上的 App 会按平台各自提示更新。

## 说明

- 安卓签名密钥为机主专属，所有版本同一把，丢了将无法覆盖更新——请离线备份。
- 上游文档与原始说明见上游仓库，本仓库仅作个人自维护用途。

## 版本清单 qfclash-release.json

QFClash 1.0.0 及以上客户端启动时读取本文件（仓库根目录），用于版本政策与服务配置，字段说明：

- `latestVersion`：最新版本号。客户端当前版本主版本号低于它时触发大版本强制更新；同主版本低于它时提示小版本更新。
- `minUsableVersion`：最低可用版本说明字段（与强制更新口径对应）。
- `retiredBelowVersion`：停服线。当前版本低于该版本时显示「该版本已停止服务」窗口。
- `maintenance`：系统维护开关。为 `true` 时，所有客户端启动即显示「系统维护中」窗口（无按钮、不可关闭），置回 `false` 后自动恢复。
- `serverBaseUrl`：账号服务地址。客户端不写死地址，以本字段为准。
- `googleClientId`：谷歌登录客户端 ID（顶层为通用值，可被平台值覆盖）。
- `platforms.android` / `platforms.windows`：分平台配置，含 `downloadUrl`（应用内更新下载地址，留空则从同版本 GitHub Release 自动获取）、`notes`（更新说明，面向用户的官方口吻）、`googleClientId`（该平台谷歌登录客户端 ID）。
