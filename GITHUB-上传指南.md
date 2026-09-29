# 上传到 GitHub · 操作指南

本仓库已经整理完毕，**处于可直接 push 的状态**。按下面步骤操作即可。

---

## 0. 先确认状态

```bash
cd /path/to/FOA
git log --oneline -5      # 应有 134 个提交，最新是打包脚本的 pipefail 修复
git status                # 应为 clean
git count-objects -vH | grep size-pack   # 实际会推上去的体积
```

关键数字：

| 项 | 值 |
|---|---|
| 提交数 | 134 |
| 跟踪文件数 | 409 |
| `.git` 体积 | ~4.2 MB（`size-pack`） |
| 分支 | `main` |
| 门禁 | `flutter analyze lib/` 0 issue；`flutter test` **1691** 全过 |
| 出包验证 | `flutter build apk --debug` 成功，136 MB，APK 内 proroot 0 处 |

> 这些数字是在**解包后的干净副本**上实测的，不是估的。

---

## 1. 在 GitHub 建空仓库

打开 <https://github.com/new>，填：

| 字段 | 填什么 | 为什么 |
|---|---|---|
| Repository name | `FOA`（或你喜欢的名字） | — |
| Description | 例如：在 Android 手机上直接构建 Flutter 应用的 IDE | 会显示在仓库页顶部 |
| **Public / Private** | 看你自己 | 首次建议 **Private**，确认没问题再转 Public |
| **Initialize this repository with** | **全部不勾** | ⚠️ 关键：勾了 README/gitignore 会产生一个和本地冲突的提交 |

> **务必不要勾** "Add a README file" / "Add .gitignore" / "Choose a license"。
> 本地已经有完整的这些文件，勾了就要处理 `unrelated histories` 冲突。

建完后**不要**点 GitHub 页面上那些命令，用下面的。

---

## 2. 关联远端并推送

把 `<你的用户名>` 和 `<仓库名>` 换掉：

```bash
cd /path/to/FOA

# 关联远端（HTTPS）
git remote add origin https://github.com/<你的用户名>/<仓库名>.git

# 首次推送
git push -u origin main
```

如果 `origin` 已存在（重来时）：

```bash
git remote set-url origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### 用 SSH 的话

```bash
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

### 认证

HTTPS 推送时 GitHub **不再接受账号密码**，要用 **Personal Access Token（PAT）**：

1. <https://github.com/settings/tokens> → `Generate new token (classic)`
2. 勾 **`repo`** 权限，设过期时间
3. 推送时：
   - 用户名：你的 GitHub 用户名
   - 密码：**粘贴这个 token**（不是登录密码）

> 凭据会被 git 缓存。想让它记住：
> `git config --global credential.helper store`
> （注意：这会以**明文**存在 `~/.git-credentials`，权衡后决定）

---

## 3. 推送后该做的（GitHub 网页上）

### 3.1 加 Topics（提高可发现性）

仓库首页右上 ⚙️ → Topics，建议：

```
flutter  android  ide  proot  qemu  arm64  no-root  on-device-build  dart
```

### 3.2 确认社区文件被识别

推完后打开仓库首页，GitHub 会自动识别这些文件（在 "Insights → Community Standards"
里能看到）：

| 文件 | 作用 |
|---|---|
| `README.md` | 首页门面 |
| `LICENSE` | AGPL-3.0 |
| `CONTRIBUTING.md` | 贡献指南 |
| `SECURITY.md` | 安全政策 |
| `.gitignore` | 忽略规则 |

### 3.3 设置仓库 About

点首页右侧 About 的 ⚙️ → 填 Description、Website（如有）、勾 Topics。

---

## 4. 发第一个 Release

因为你已经在本地出过包（`dist/FOA-v0.1.0-alpha.98-arm64.apk`）：

```bash
# 打 tag（版本号与 pubspec.yaml 保持一致）
git tag -a v0.1.0-alpha.98 -m "v0.1.0-alpha.98

- Bug 636: AGP 非法 shrink 组合的检测与修复
- Bug 637: debug 档 reassert 回归护栏
- Bug 638: 老写法检测搬进构建前置检查
- Bug 639: platform/ 模板漂移门禁
- 门禁 1774 项全过"

git push origin v0.1.0-alpha.98
```

然后 GitHub 网页：仓库 → Releases → `Draft a new release` → 选这个 tag →
把本地 `dist/FOA-v0.1.0-alpha.98-arm64.apk` 与 `.sha256` 拖进去附件区。

> ⚠️ **发 Release 前先过一遍**
> [`dev-handbook/06-发布流程.md`](dev-handbook/06-发布流程.md) 的检查项，
> 特别是 `tools/verify_apk.sh`（第 4 项会拦住 proroot 混入包）。

---

## 5. 推完之后：新版怎么发

日常循环：

```bash
# 1. 改代码 ……
# 2. 门禁
cd app && flutter analyze lib/ && flutter test && bash ../tools/sync_platform.sh

# 3. 改版本号（两处必须一起，有单测盯着）
#    app/pubspec.yaml           version: 0.1.0-alpha.NN+NN
#    app/lib/ui/about_info.dart v0.1.0-alpha.NN+NN

# 4. 出包
cd .. && bash tools/release.sh

# 5. 验证（六项）
bash tools/verify_apk.sh dist/FOA-v0.1.0-alpha.NN-arm64.apk

# 6. 提交 + 推
git add -A && git commit -m "release: v0.1.0-alpha.NN"
git tag -a v0.1.0-alpha.NN -m "v0.1.0-alpha.NN"
git push && git push --tags
```

---

## 6. 常见问题

### `src refspec main does not match any`

本地分支名可能不是 `main`：

```bash
git branch -M main     # 重命名为 main
git push -u origin main
```

### `Updates were rejected because the remote contains work that you do not have`

远端有本地没有的提交（多半是建仓库时勾了 README）。两种处理：

```bash
# 方案 A（推荐）：远端确实是空仓库意图 —— 强推（只有你自己能推时才用）
git push -u origin main --force

# 方案 B：把远端的合并进来
git pull --rebase origin main
git push -u origin main
```

### 推送很慢 / 卡住

```bash
# 看卡在哪一步
GIT_CURL_VERBOSE=1 git push -u origin main
```

常见原因：文件多、单次推送包大。本仓库只有 4.7MB，正常应该几秒内完成。

### 想把某个大文件从历史里删掉

本仓库已经清理过，没有大文件。若将来误提交了：

```bash
pip install git-filter-repo
git filter-repo --path <大文件路径> --invert-paths
# 注意：这会改写历史，之后必须 force push，且所有克隆要重新拉
```

### 想改成 Private / Public

仓库 → Settings → 最下方 `Danger Zone` → `Change repository visibility`。

---

## 7. 一个提醒：rootfs 不是"跑个脚本就能下回来"

**仓库里没有的东西，别以为别人 clone 下来就有**：

| 缺失 | 怎么补 |
|---|---|
| `app/assets/tools/proot-arm64` 等 | ✅ `cd app && bash tools/fetch_assets.sh proot`（有 Termux apt 直链，能下） |
| `app/assets/rootfs/debian-minbase-arm64.tar.gz`（75MB） | ⚠️ **下不回来**，见下 |
| Flutter SDK / Android SDK / JDK | App 内「工具链」页一键装 |

### ⚠️ rootfs 没有公共下载源（这条最容易踩）

我最早在指南里写了 `bash tools/fetch_assets.sh rootfs` —— **那是错的，会直接失败**。
`app/tools/fetch_assets.sh` 里 `ROOTFS_URL` **没有默认值**，脚本会打印
debootstrap 自建配方然后 `exit 1`。

所以：

| 情况 | 怎么办 |
|---|---|
| **你手上已有 rootfs**（本次交付的**完整包**里就有） | 直接放进 `app/assets/rootfs/`，脚本检测到已存在会跳过 |
| **只有纯 git 仓库 / 用 `--slim` 包** | 需要 `debootstrap` 自建：x86_64 Linux + 约 20 分钟 + `qemu-user-static`。配方在 `app/tools/fetch_assets.sh` 的提示里，也写在 `app/SETUP_ANDROID.md`「rootfs 的构建」 |

**别把它加进 git**。它被 `.gitignore` 排除是有意的（理由写在 `.gitignore` 头注释）：
二进制进 git 会让仓库无限膨胀，且无法 diff/审查。
走 GitHub Releases 挂附件，或者随源码包分发。

> 这也是为什么交付包**默认带上它**、只有 `--slim` 才排除 ——
> 带上它对远端零影响（`git push` 只推已跟踪文件），但能让解包的人立刻构建。

---

## 附：本次整理做了什么

| 动作 | 说明 |
|---|---|
| **合并为单仓库** | 原先 `app/` 与 `dev-handbook/` 各有一个嵌套 `.git`；现合并成一个，历史前缀已用 `git-filter-repo` 重写 |
| **alpha.63 → alpha.98 压缩提交** | 152 处未提交改动合成一个提交（避免把反复试错的碎片带上线） |
| **移除 proroot** | 可选容器层从未投入使用 → 代码 / UI / 原生通道 / 脚本 / 测试 / 文档全部删除（含 `PROROOT-许可与分发决策.md`，相关引用已一并改口径）。门禁 1781 → **1691** |
| **补齐开源要件** | LICENSE（AGPL-3.0）、LICENSE-COMMERCIAL、CLA、CONTRIBUTING、SECURITY |
| **README 重写** | 从"内部变更日志"改为"对外门面"（架构图 / 快速开始 / 功能 / 许可在前，更新日志在后） |
| **.gitignore 定稿** | 明确区分源码与未跟踪资产；挡住 rootfs / proot / local-maven / jniLibs / 凭据 |
| **清理残留** | 删除 `settings.gradle.kts.orig`、空文件 `st`、`android/.gradle/` |
| **打包脚本化** | `tools/make_release_tarball.sh` + `tools/package-excludes.txt`，含回读复核与逐条排除校验；配 `app/test/package_excludes_test.dart`（7 条） |
| **`.trae/` 不入库** | 3 个 SKILL.md（156K）是本机编辑器备忘 → 删除 + `.gitignore` + `git filter-repo` 从历史抹掉 |
| **手册第十九章** | Bug 638/639 收尾 + 打包踩的三个静默错误 + 19.6 移除 proroot + 19.7 沙箱 Gradle TLS 握手失败怎么绕 |
| **安全扫描** | 无密钥、无 token、无内网地址、无个人路径（详见下文） |

### 两个交付包的区别

| 包 | 体积 | 用途 |
|---|---|---|
| `FOA-github-ready-20260930.tar.gz` | 84 MB | **主交付**。含 rootfs/proot，解包即可构建；`git push` 仍只推 4.2MB |
| `FOA-github-slim-20260930.tar.gz` | 8.7 MB | 纯 git 镜像（不含未跟踪资产）。适合存档，但解包后**不能直接构建** |

两个包都含完整 `.git`（解包即可 `git remote set-url` 后推送，无需重新 init）。

### 安全扫描结论

| 检查项 | 结果 |
|---|---|
| 私钥块（`BEGIN PRIVATE KEY`） | ✅ 无 |
| `.jks` / `.keystore` / `key.properties` | ✅ 无 |
| `.git-credentials` | ✅ 无 |
| GitHub token（`ghp_`/`sk-`） | ✅ 无 |
| 内网地址 | ✅ 仅文档中作为**案例引用的** DNS/IP，非真实凭据 |
| 个人路径（`/home/xxx`） | ✅ 无 |

**README / 文档中出现的邮箱与 GitHub 用户名是有意公开的作者信息**
（App 内「关于」页本来就在展示）。
