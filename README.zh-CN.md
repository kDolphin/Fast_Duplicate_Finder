# Fast Duplicate Finder（快速重复文件查找器）

**[English](README.md)** | **简体中文**

原生 **macOS** 应用：在本地盘与网络卷（NAS）上查找并清理**重复文件**。默认极速扫描，清理前有安全与用途风险提示。

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.5-blue" alt="version" />
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="platform" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-green" alt="arch" />
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="license" />
</p>

## 功能

- **极速扫描** — 按大小分桶 + xxHash 采样；**需复核**组可再做**精确比对**（全文）
- **整包比较** — `.app`、光盘包等保持不透明，按整包对象比较（结构 + 轻量内容校验）
- **用途风险保护** — 内容相同但角色不同（语言路径、多产品同角色、套壳入口等）会标记，且**默认不勾选删除**
- **自行勾选清理** — 每项可勾选；清理按钮只处理你的选择；默认进废纸篓
- **网络 / NAS** — 较低并发、路径序哈希，更适合网络盘
- **扫描缓存** — 跨次复用哈希；包指纹在 mtime 未变时可跳过内部遍历
- **现代界面** — 大纲式结果、筛选（全部 / 需复核 / 整包）、搜索、耗时拆分
- **语言** — 英 / 简中，**跟随系统「语言与地区」**（无应用内切换）
- **设置** — 齿轮或 **⌘,**

## 系统要求

- macOS **13** 或更高  
- 推荐 **Apple Silicon**（`build.sh` 目标为 `arm64`）

## 安装

### 下载安装（推荐）

在 [Releases](https://github.com/kDolphin/Fast_Duplicate_Finder/releases) 下载最新
**`FastDuplicateFinder.zip`**：

1. 解压  
2. 将 **`Fast Duplicate Finder.app`** 拖入「应用程序」  
3. 首次启动：右键 App → **打开**（ad-hoc 签名，**未** Apple 公证）

[历史版本 →](https://github.com/kDolphin/Fast_Duplicate_Finder/releases)

### 从源码构建

```bash
git clone https://github.com/kDolphin/Fast_Duplicate_Finder.git
cd Fast_Duplicate_Finder
bash build.sh
open "build/Fast Duplicate Finder.app"
```

安装到「应用程序」：

```bash
cp -R "build/Fast Duplicate Finder.app" /Applications/
```

### Xcode（可选）

```bash
open finddup.xcodeproj
# Scheme: finddup · 产品名: Fast Duplicate Finder
```

## 使用方法

1. 在侧栏添加一个或多个文件夹。  
2. 点击 **开始扫描**。  
3. 查看重复组：展开、勾选要删的项（用途风险组默认不勾）。  
4. 需要时点 **精确比对需复核** 做全文确认。  
5. **清理** → 预览 → 按设置进废纸篓或永久删除。  

设置：**⌘,** 或齿轮。

## 更新日志

### 1.0.5

- **目录记住** — 选过的扫描位置下次启动仍在（安全范围书签）
- **首次扫描** — 哈希缓存在后台加载，不再卡在 5%「正在扫描文件」
- **清理** — 本机 + NAS 混选时本机仍进废纸篓；清理后更新结果，不再整库重扫
- **比对缓存** — 精确比对的 SHA-256 不再把下次极速扫描拆成两组
- **侧栏** — 添加 / 清空 / 拖放可点整块区域；无重复与取消扫描有独立结果页

### 1.0.4

- **扫描缓存** — 按扫描根目录合并写入，扫本机不再冲掉 NAS（`/Volumes/…`）哈希；长网络哈希过程中渐进落盘
- **NAS 进度** — 显示 `hits · new · conc`，仅新增文件需哈希时缓存命中一目了然

### 1.0.3

- **结果列表** — 全部展开/收起为 O(1)（数万组不再卡顿）；用途风险徽章文案预计算
- **清理** — 按钮数量与删除范围跟随当前筛选（全部 / 需复核 / 整包）及搜索
- **设置缓存** — 扫描或清除后条目数即时刷新（无需重启应用）

### 1.0.2

- **NAS 枚举** — 首层子目录并行列出（并发 **6**）；包元数据复用，减少额外 SMB 往返
- **大库准备 / 收尾** — 更快的列表指纹、内存热缓存、取消不写残缺快照；建组不再触发文件系统路径解析；缓存异步落盘
- **用途风险清理体验** — 顶栏「按建议勾选」与组内「勾选其余」（默认仍不自动勾选）
- **耗时统计** — 拆分条与墙钟总时长对齐；分钟级显示更易核对

### 1.0.1

- **NAS 性能** — 三点采样窗口改为 **12 KB**；网络哈希并发固定为 **6**
- **取消 / 续扫** — 中断扫描不再写入不完整的结果快照（避免下次扫描“假完成”）；已算完的单文件哈希仍会保留以便加速续扫

### 1.0.0

- 首次公开发布

## 已知限制（v1.0）

| 项 | 说明 |
|----|------|
| 沙盒 | 只能扫描你授权的目录 |
| 签名 | ad-hoc 签名，未公证 |
| 启发式 | 用途风险依赖路径/命名规则，极端情况仍可能误判 |
| 架构 | `build.sh` 以 arm64 为主 |

## 隐私

| 行为 | 说明 |
|------|------|
| 读取 | 你选择的文件夹（App Sandbox + 用户选定文件） |
| 写入 | 仅在你确认清理后 |
| 网络 | 仅你挂载并选择扫描的网络卷 |
| 云端 | **不上传**；扫描在本机完成 |

## 项目结构

```text
finddup/                 # 源码、资源、本地化
  Models/  Services/  Views/
  en.lproj/  zh-Hans.lproj/
build.sh                 # → build/…app + zip
finddup.xcodeproj
LICENSE
```

## 技术栈

- Swift / SwiftUI  
- CryptoKit + 自研 xxHash  
- **无第三方依赖**

## 构建产物

```bash
bash build.sh
# → build/Fast Duplicate Finder.app
# → build/FastDuplicateFinder.zip
```

## 故障排查

| 现象 | 处理 |
|------|------|
| 权限不足 | 重新选择文件夹并在系统提示时授权 |
| NAS 很慢 | 保持卷已挂载；先完整扫一次预热缓存 |
| 语言不对 | 在 **系统设置 → 语言与地区** 修改系统或 App 语言后重启应用 |
| 构建失败 | 使用完整 Xcode；在仓库根目录执行 `bash build.sh` |

## 许可证

[MIT](LICENSE)

## 仓库

[github.com/kDolphin/Fast_Duplicate_Finder](https://github.com/kDolphin/Fast_Duplicate_Finder)
