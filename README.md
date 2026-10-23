<div align="center">

# SSH Restart

**开源 · 跨平台 · 端到端加密** 的现代 SSH 客户端

功能对标 FinalShell，界面更现代，内置谷歌云盘加密备份，助你在多台设备间安全同步服务器信息。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.35.7-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Android-lightgrey.svg)](#下载)
[![Release](https://img.shields.io/github/v/release/gunzi-666/ssh-restart?include_prereleases)](https://github.com/gunzi-666/ssh-restart/releases)

</div>

> 完全开源，无任何付费墙、无账号体系、无数据上报。所有数据都在你自己手里。

## 目录

- [功能特性](#功能特性)
- [下载](#下载)
- [从源码构建](#从源码构建)
- [从 FinalShell 迁移](#从-finalshell-迁移)
- [谷歌云盘备份配置](#谷歌云盘备份配置)
- [加密备份说明](#加密备份说明)
- [技术栈](#技术栈)
- [常见问题](#常见问题)
- [开源协议](#开源协议)

## 功能特性

**服务器管理**
- 首页服务器列表，支持列表 / 卡片两种视图，单页滚动显示全部服务器，按添加顺序 / 名称 / 地址 / 最近连接排序
- 侧边栏可拖动调整宽度；仿 FinalShell 的文件夹树，展开文件夹即可看到其中的服务器，点击服务器只显示该台，点击文件夹显示整组
- 收藏、最近连接、多级分组（支持拖拽服务器到分组）
- 多选后批量连接、批量复制连接信息、批量移动到分组、批量删除
- 全局搜索（`Ctrl K` / `⌘ K`），按认证方式、连接类型筛选
- 一键连接、一键复制连接信息（IP / 端口 / 用户名 / 密码）

**连接过程可视化**
- 参考 xterminal 的连接进度弹窗：初始化配置 → 连接服务器 → 配置连接协议 → 认证用户 → 打开终端，逐步显示并附带详细日志
- 连接失败时停留在首页并标出失败的步骤，可一键复制日志或重新连接；成功后才进入终端页
- 首次连接时在同一弹窗内核对并信任主机指纹；指纹变化时醒目警告，防范中间人攻击
- 跳板机的每一跳都会单独显示进度

**SSH 终端**
- 多标签页、断线自动重连、复制/粘贴、选中即复制、右键粘贴
- 终端内直接输入，完整支持交互式脚本
- 可自定义字体、字号与配色主题
- 命令输入框、历史命令、快捷命令、向所有标签广播命令

**连接方式**
- 密码 / 私钥认证
- HTTP、SOCKS5 代理
- 跳板机（等价 `ssh -J`，支持多级）
- 本地 / 远程 / 动态端口转发
- 兼容老旧服务器的传统加密算法开关

**状态监控**
- CPU、内存、交换、系统负载
- 网卡上传/下载速率与实时曲线
- 延迟曲线、磁盘占用
- 进程列表（支持结束进程）

**SFTP 文件管理**
- 上传 / 下载队列
- 新建 / 重命名 / 删除、权限与属主修改、压缩 / 解压
- 可选「跟随终端目录」

**内置代码编辑器**
- 在 SSH 标签内以子标签打开远程文件，可同时编辑多个文件
- 行号、按扩展名自动语法高亮、查找替换
- 缩略图（minimap）、行书签、`Ctrl S` 保存

**VNC 远程桌面**
- 纯 Dart 实现的 RFB 协议，支持直连或经 SSH 隧道连接

**加密备份与同步**
- 会话、密码、私钥、分组、快捷命令、设置等全部用你设定的密钥本地加密
- 可导出到文件，或上传到谷歌云盘；其他设备用相同密钥即可导入
- 备份文件可直接拖进设置页导入，无需逐级选择文件
- 支持从 FinalShell 一键导入服务器（自动解密密码、还原分组与私钥）

**本机数据与安全**
- 数据保存在本机 SQLite 数据库中，旧版 `data.json` 会自动迁移，校验无误后删除
- 可设置启动密码，每次打开软件需先解锁
- 「清除所有数据」需输入确认文字，会彻底删除数据库及相关文件，不留残余

**界面与主题**
- 三套内置界面风格：默认（shadcn/ui）、Fluent（Windows 11）、Ant Design，设置中一键切换
- 亮色 / 暗色 / 跟随系统，可自定义主题色
- 记住窗口位置、大小与最大化状态，下次打开保持原样

**自动更新**
- 「设置 → 关于 → 检查更新」从 GitHub Release 获取最新版本并显示更新说明
- Windows / macOS 应用内下载，校验 SHA-256 后自动替换并重启；Android 跳转浏览器下载 APK

**跨平台**
- Windows、macOS、Android（iOS 规划中）
- Windows 采用自绘标题栏，macOS 使用系统原生标题栏

## 下载

前往 [Releases](https://github.com/gunzi-666/ssh-restart/releases) 页面下载对应平台的安装包：

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Windows | `SSH-Restart-Windows.zip` | 解压后运行 `ssh_restart.exe` |
| macOS | `SSH-Restart-macOS.zip` | 解压得到 `.app`；首次打开若提示未签名，请在「系统设置 → 隐私与安全性」中允许 |
| Android | `SSH-Restart-universal.apk` | 通用包，或选择按 CPU 架构拆分的 APK |

已安装 1.0.8 及以上版本时，可直接在「设置 → 关于 → 检查更新」中一键升级。Windows 版若放在 `Program Files` 等需要管理员权限的目录，自动更新无法写入，请手动下载覆盖，或将程序放到普通目录。

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/) 3.35.7 或兼容版本。

```bash
flutter pub get

# 运行
flutter run -d windows   # 或 macos / <Android 设备>

# 构建
flutter build windows
flutter build macos
flutter build apk --release

# 单元测试
flutter test
```

## 从 FinalShell 迁移

在「设置 → 备份与同步 → 从 FinalShell 导入」中选择以下任意一种来源：

- 自动检测到的 FinalShell 数据目录（Windows：`%LOCALAPPDATA%\finalshell`；macOS：`~/Library/FinalShell`）
- 手动选择 FinalShell 目录或其中的 `conn` 文件夹
- 包含连接配置的 `.zip` 或 `.json` 文件（可多选）

导入前会显示预览：识别到的服务器数量、密码解密结果、分组与私钥匹配情况。导入采用合并方式，主机、端口、用户名相同的服务器会自动跳过，不会修改本机已有数据。目前仅导入 SSH 连接。

## 谷歌云盘备份配置

本软件**不需要注册任何账号**。谷歌云盘备份使用你自己的 Google OAuth 客户端，步骤如下：

1. 打开 [Google Cloud Console](https://console.cloud.google.com/)，新建一个项目。
2. 在「API 和服务 → 库」中启用 **Google Drive API**。
3. 在「OAuth 同意屏幕」中把你自己的 Google 账号添加为**测试用户**。
4. 在「凭据 → 创建凭据 → OAuth 客户端 ID」中，应用类型选择 **桌面应用（Desktop app）**（这一点很重要，授权通过本机回环地址完成，其他类型无法工作）。
5. 回到本软件「设置 → 备份与同步」，填入客户端 ID 与密钥，点击「授权」，在浏览器登录一次谷歌账号即可。之后令牌会自动刷新，无需重复登录。

> 备份只会操作谷歌云盘中由本软件创建的 `SSH-Restart-Backup` 文件夹，不会访问你的其他文件。

## 加密备份说明

- 在「设置 → 备份与同步」中设定**加密密钥**，备份文件中的敏感信息（密码、私钥等）会用该密钥通过 PBKDF2-HMAC-SHA256 派生并以 AES-256-GCM 加密。
- 在另一台设备上安装本软件、设定**相同的密钥**，上传或导入备份文件后即可还原所有会话信息。
- 密钥只保存在本地，请务必牢记；**密钥丢失将无法解密已有备份**。

## 技术栈

Flutter · dartssh2 · xterm.dart · re_editor · sqlite3 · googleapis · cryptography · pointycastle · archive · window_manager · desktop_drop

## 常见问题

**数据存在哪里？会上传到你们的服务器吗？**
所有数据都保存在本地的 SQLite 数据库 `ssh_restart.db` 中（Windows：`%APPDATA%\com.sshrestart\ssh_restart`）。除非你主动配置并使用谷歌云盘备份，否则不会有任何数据离开你的设备；即便使用备份，敏感信息也是加密后才上传，且目标是你自己的谷歌云盘。检查更新只会请求 GitHub 公开接口，不携带任何个人数据。

**本地数据库是加密的吗？**
本地数据库不加密，安全性依赖于操作系统账户本身。如果担心他人使用你的电脑时打开软件，可以在「设置 → 常规 → 安全」中开启启动密码；需要换机或清理时，可使用「设置 → 常规 → 数据 → 清除所有数据」彻底删除。

**连接失败怎么排查？**
连接进度弹窗会标出具体失败在哪一步（网络连接、协议协商、认证或打开终端），点击「复制日志」即可获取完整过程（不含密码），方便定位问题或反馈 issue。

**macOS 打开提示「已损坏」或「无法验证开发者」怎么办？**
这是因为应用未经 Apple 签名。请在「系统设置 → 隐私与安全性」中点击「仍要打开」，或对 `.app` 执行 `xattr -dr com.apple.quarantine <路径>`。

**忘记加密密钥还能恢复备份吗？**
不能。密钥仅保存在本地且不参与任何明文存储，丢失后无法解密，请妥善保管。

## 开源协议

[MIT](LICENSE)
