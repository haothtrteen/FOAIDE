# Flutter on Android

在安卓设备上本地构建 Flutter 应用的 IDE。纯本地，不依赖云端构建。

> 当前阶段：**Step 1 · proot + rootfs Hello World**
>
> 目标：验证地基——proot 能正常启动最小 Debian rootfs 并执行命令。

## 当前功能（Step 1）

- ✅ App 壳 + Material 主题
- ✅ proot 二进制加载（assets → app 私有目录）
- ✅ 最小 Debian rootfs 解压
- ✅ 执行 shell 命令并回显输出
- ✅ 环境状态检测（已安装 / 未安装）

## 项目结构

```
lib/
  main.dart                    # 应用入口
  core/
    theme.dart                 # 主题配置
  env/
    proot_manager.dart         # proot 进程管理
    env_installer.dart         # 环境安装器（rootfs 解压、工具部署）
  ui/
    home_page.dart             # 主页
    terminal_page.dart         # 终端输出页
assets/
  tools/                       # proot 等二进制工具（见 README）
  rootfs/                      # rootfs tarball（见 README）
```

## 快速开始

### 1. 获取 proot 二进制

从以下渠道获取 arm64 版 proot：

- **Termux proot**：`https://github.com/termux/proot/releases`
- 或自行从源码交叉编译

将 `proot` 二进制重命名为 `proot-arm64` 放到 `assets/tools/` 目录。

### 2. 获取最小 Debian rootfs

- 方式 A：用 `debootstrap --variant=minbase` 制作
- 方式 B：从 Docker 导出（`docker export` debian:bookworm-slim → tar）
- 方式 C：用 proot-distro 的预构建 tarball

将 rootfs 打包为 `debian-minbase-arm64.tar.gz` 放到 `assets/rootfs/` 目录。

> 体积参考：minbase 约 40-60MB，压缩后约 15-25MB。

### 3. 构建运行

```bash
cd app
flutter pub get
flutter run
```

## Step 1 验证

打开 App → 点击"初始化环境" → 等待解压完成 → 点击"运行测试命令" → 看到 `hello` 输出即表示成功。

详细验证清单见 [dev-handbook/03-测试指南.md](../dev-handbook/03-测试指南.md) Step 1 部分。

## 许可证

本项目核心代码采用 **AGPL-3.0** 许可。
第三方组件许可证详见 `THIRD-PARTY-NOTICES`（后续补充）。
