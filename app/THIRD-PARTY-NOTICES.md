# THIRD-PARTY NOTICES

本文件列出随本应用分发/使用的第三方组件及许可证（合规流程见 dev-handbook/05-许可证合规.md）。

| 组件 | 版本 | 许可证 | 分发方式 | 源码获取 |
|---|---|---|---|---|
| proot（Termux 分支构建） | 按 Release 附注 | GPL-2.0 | APK 内嵌二进制（`jniLibs/libproot.so` 或 `assets/tools/proot-arm64`） | https://github.com/termux/proot |
| Debian rootfs (minbase) | bookworm | 各软件包自有自由许可证（DFSG） | APK 内嵌 tarball，首次运行解压 | https://www.debian.org/distrib/ |

说明：

- GPL-2.0 组件（proot）以**独立进程**方式调用，与本项目代码不构成静态/动态链接；
- 按许可证要求，任何对外 Release 均须附 proot 对应版本源码或以上述链接方式提供；
- Debian rootfs 内软件包的许可证清单随包（`/usr/share/doc/*/copyright`）自带，可通过 App 内命令查看。

> 后续引入新组件时必须先更新此表（检查清单见 dev-handbook/05-许可证合规.md）。
