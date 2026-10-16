# LiteTab 🚀

<p align="center">
  <img src="Resources/AppIcon.icns" width="128" height="128" alt="LiteTab Icon" />
</p>

<p align="center">
  <b>极简轻量 · 原生毫秒级响应 · 窗口缩略图切换器 for macOS</b><br>
  <i>A lightweight, lightning-fast native window switcher with real thumbnails for macOS.</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013.0+-blue?logo=apple" alt="Platform" />
  <img src="https://img.shields.io/badge/Language-Swift%206%20%2F%20SwiftUI-orange?logo=swift" alt="Language" />
  <img src="https://img.shields.io/badge/Footprint-~20MB-brightgreen" alt="Memory" />
  <img src="https://img.shields.io/badge/Idle%20CPU-0.0%25-brightgreen" alt="CPU" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License" />
</p>

---

## 💡 为什么开发 LiteTab？

很多 macOS 用户习惯使用 Windows 风格的 `Alt + Tab`（查看具体的每一个窗口画面，而非仅仅是应用图标）。目前市面上最流行的开源工具是 **AltTab**。

然而在长期的重度使用中，AltTab 存在几个严重的体验痛点：
1. **输入冻结与事件延迟（Event-Tap Lag）**：AltTab 使用全局 CGEventTap 拦截键盘鼠标事件。系统卡顿时，EventTap 延迟可能飙升到十几秒甚至死锁，导致整个屏幕鼠标点击完全无反应，必须到 Dock 栏重新激活应用。
2. **内存严重膨胀**：常驻物理内存轻松突破 **300MB ~ 500MB**，未压缩的高清视网膜全屏位图大量驻留堆中。
3. **后台幽灵窗口干扰**：现代 macOS 应用（VS Code、FaceTime、信息、ChatGPT）在后台维护大量 500×500 的离线辅助服务窗口，容易出现多余的重复卡片。

**LiteTab 为彻底解决上述痛点而生！** 纯原生 Swift + SwiftUI 编写，零第三方依赖，追求极客级别的轻量、可靠与毫秒级爆发速度。

---

## ⚡️ 核心特性

- 🖼️ **真实高清窗口缩略图**：实时显示每个窗口当前画面的微缩快照，所见即所得。
- 📉 **自研等比下采样技术（Downscaling）**：
  - 抓取视网膜全屏窗口后，即时通过 `CGContext` 极速下采样至目标物理像素（最大 480px）；
  - **单张位图内存骤降 96.5%**（从 37.3MB 降至 0.48MB），彻底杜绝内存泄漏；
  - 真实物理内存（Footprint）长期稳定在 **20MB ~ 30MB 左右**，待机 CPU **0.0%**。
- ⚡ **零阻塞 0ms 瞬间呼出**：
  - 放弃脆弱的全局 EventTap，采用 Carbon 底层系统热键引擎（`RegisterEventHotKey`）；
  - 主线程只执行毫秒级窗口扫描（~50ms），最小化窗口索引移至后台静默队列（`MinimizedScanner`），彻底消灭卡顿。
- ⌨️ **快捷键任意自定义 & 快速预设**：
  - 支持在设置界面内**点击一键录制**任意组合键（⌘ / ⌥ / ⌃ / ⇧ 搭配任意键）；
  - 内置 `⌥ Tab`、`⌘ Tab`、`⌃ Tab`、`⌥ \`` 快速预设，点击即刻生效；
  - 智能释放适配：松开主修饰键自动平滑激活目标窗口。
- 🚀 **面板内高频快捷操作**：
  - `W`：一键关闭选中窗口
  - `Q`：一键彻底退出当前应用
  - `M`：一键最小化窗口到 Dock
  - `H`：一键隐藏当前应用
  - `Esc`：取消切换
  - `Enter` / 鼠标点击：直接进入目标窗口
- 🗂️ **支持最小化窗口还原**：完美识别并显示 Dock 栏里的最小化窗口，切换时自动弹起恢复。
- 🎨 **触控板双向手势**：支持触控板双指横向/纵向滑动顺滑轮播切换卡片。
- ⚙️ **原生 SwiftUI 偏好设置**：
  - 开机自启动管理（采用 macOS 13+ `SMAppService` 原生服务）
  - 紧凑 / 标准 / 宽大 3 档卡片尺寸实时预览与切换
  - 内存截图缓存时长滑块与一键立即清空缓存
  - 实时健康监控（真实物理内存 Footprint、待机 CPU 消耗）

---

## 📊 性能数据横向对比

| 衡量维度 | AltTab | macOS 原生 (⌘ Tab) | **LiteTab** |
| :--- | :---: | :---: | :---: |
| **实时窗口画面** | ✅ 支持 | ❌ 仅支持应用图标 | **✅ 支持实时真实画面** |
| **真实内存足迹 (Footprint)** | ~300MB - 500MB | 系统级 | **🔥 仅 20MB ~ 30MB** |
| **待机 CPU 消耗** | 0.5% ~ 2.0% | 0.0% | **🔥 0.0%** |
| **呼出延迟** | 偶尔受 EventTap 阻塞卡顿 | 0ms | **🔥 毫秒级瞬间弹出 (<50ms)** |
| **输入冻结风险** | ⚠️ 有（EventTap 死锁） | 极低 | **🔥 0 风险（Carbon 独立管道）** |
| **窗口快捷键 (W/Q/M/H)** | 支持 | 仅退出应用 (Q) | **✅ 完整原生支持** |
| **代码体积与依赖** | 庞大，多项 C++ 库 | 闭源系统组件 | **🔥 单文件 Swift，零第三方依赖** |

---

## 🛠️ 安装与使用

### 1. 源码一键构建并安装（推荐）

克隆本项目到本地，在终端执行自带的构建脚本：

```bash
git clone https://github.com/vvrfxyz/LiteTab.git
cd LiteTab

# 编译并直接安装到 /Applications 并启动
./build.sh install
```

如果只需本地构建调试，不自动安装到应用程序目录，直接运行：
```bash
./build.sh
```
构建产物将输出在 `./build/LiteTab.app`。

---

## 🔒 隐私与系统权限说明

LiteTab 尊重用户隐私，所有操作均在本地内存中完成，**绝不保存、绝不上传、绝不上报任何数据，无需任何网络访问权限**。

初次启动时，LiteTab 需要授予 **「屏幕与系统音频录制」** 权限：
- **用途**：仅用于捕获各个窗口的实时外观以生成缩略图卡片。
- **授权方式**：
  1. 系统会弹出授权提示，或前往 **「系统设置」->「隐私与安全性」->「屏幕与系统音频录制」**；
  2. 勾选 **LiteTab** 允许；
  3. 如果重新编译过代码，LiteTab 已配置固定的 `Designated Requirement` 签名机制，不会丢失已有的授权记录。

---

## ⌨️ 快捷操作说明

| 场景 | 按键 | 功能说明 |
| :--- | :--- | :--- |
| **全局唤醒** | `⌥ Tab` *(可自定义)* | 呼出切换器并聚焦下一个窗口 |
| **顺序切换** | 按住修饰键继续按 `Tab` | 向右/顺时针循环选中窗口 |
| **逆序切换** | `Shift + Tab` | 向左/逆时针循环选中窗口 |
| **触控板/滚轮** | 双指左右或上下轻滑 | 轮播切换高亮卡片 |
| **确认切换** | 松开修饰键 / `Enter` / 鼠标左键 | 激活并聚焦所选窗口（若是最小化窗口则从 Dock 恢复） |
| **关闭窗口** | `W` | 瞬间关闭当前高亮选中的单个窗口 |
| **退出程序** | `Q` | 彻底退出当前高亮窗口所属的应用 |
| **最小化** | `M` | 将当前窗口最小化到 Dock |
| **隐藏应用** | `H` | 隐藏当前高亮窗口所属的应用 |
| **取消退出** | `Esc` / 窗口外空白处点击 / 右上角关闭按钮 | 关闭切换面板，不切换任何窗口 |
| **偏好设置** | 点击顶部菜单栏 `⇥` 图标 -> 「偏好设置...」 | 打开 GUI 配置面板与健康诊断 |

---

## 🏗️ 架构与设计原理

- **动态链接 CoreGraphics 内部接口**：针对 macOS 15+ 弃用旧版 API 的问题，通过 `dlopen` 动态加载 `CGWindowListCreateImage` 并指定 `kCGWindowListOptionIncludingWindow`，准确抓取单个窗口实际内容而非桌面背景全屏。
- **精准过滤 500×500 离线幽灵窗口**：严格过滤 `kCGWindowListOptionOnScreenOnly`，辅以 `AXStandardWindow` 与 `kAXMinimizedAttribute` 区分真正的用户最小化窗口与后台离线服务窗口。
- **后台异步渲染流水线**：
  - 主线程生成骨架列表，0ms 渲染卡片边框与应用图标；
  - 缩略图抓取与下采样分发到高优先级后台并发队列（`qos: .userInteractive`）；
  - 抓取完成后以异步回调平滑刷新卡片，主线程绝不掉帧。

---

## 📄 开源许可证

本项目采用 [MIT License](LICENSE) 开源协议。
