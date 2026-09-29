# local-maven · 离线构建兜底仓库

**这不是项目的一部分，是构建沙箱在断网时的应急手段。**

## 为什么存在

构建机（沙箱）对国外网络封闭时，`flutter build apk` 会挂：

```
> Could not resolve io.flutter:arm64_v8a_release:1.0.0-06a2e2a1...
   > Could not HEAD 'https://download.flutter.io/...'
      > Remote host terminated the handshake
```

Flutter 的 Gradle 插件会往仓库列表注入 `download.flutter.io` /
`dl.google.com` / `repo.maven.apache.org`，优先级高于 `settings.gradle.kts`
里配的阿里云镜像；而这两个 artifact **只有官方源有**，阿里云镜像里没有
（Flutter engine 不在 Maven Central 分发）。

## 怎么用

里面的 `io/flutter/{arm64_v8a_release,flutter_embedding_release,
arm64_v8a_debug,flutter_embedding_debug}/<版本>/` 是从**本机 Gradle 缓存**
摊出来的。**四个都要摊**：

- 只摊 release 两个 → `flutter build apk --release` 能过，
  但 `--debug` 会挂在 `Could not resolve io.flutter:arm64_v8a_debug`
  （alpha.98 实测踩到，详见 `dev-handbook/04` 19.7）；
- debug 的 engine jar 是 **180MB**（release 只有 42MB），磁盘要留够。

```bash
M2=android/local-maven
for art in arm64_v8a_release flutter_embedding_release \
           arm64_v8a_debug flutter_embedding_debug; do
  ver=1.0.0-06a2e2a110089dff50fe635cffd2a61e1b24fbcd   # 换 Flutter/engine 版本时改这里
  mkdir -p "$M2/io/flutter/$art/$ver"
  find /root/.gradle/caches/modules-2/files-2.1/io.flutter/$art/$ver \
    -type f -exec cp {} "$M2/io/flutter/$art/$ver/" \;
done
```

`settings.gradle.kts` 里已经把它挂成最后一个仓库，并配了
`repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)`
（默认的 `FAIL_ON_PROJECT_REPOS` 会把 `build.gradle.kts` 里的镜像也判为非法）。

## 注意事项

- **有网时它不影响正常构建**：排在 `google()` / `mavenCentral()` 之后，
  只有前面都拿不到才会落到这里。
- **升级 Flutter / engine 后要重新摊一次**：目录名里的
  `1.0.0-<engine revision>` 会变，旧的留着无害但没用。
- **不要提交进仓库**（`arm64_v8a_release` 的 aar 有 42MB）。
  细节见 `dev-handbook/04-常见Bug与解决方案.md` 的 Bug 616。
