# 贡献指南

本仓库是 **kkFileView 的源码构建 / 打包流水线**，不包含 kkFileView 源码本身

本分支是 **4.x 线**（Java 8 / Spring Boot 2.4.2 / 无 actuator）；`main` 分支是 5.x 线
（Java 21 / Spring Boot 3.5 / 有 actuator）。两条线的 JDK、探活方式、发布标签都不同
（`latest-4.x` vs `latest`），改动请发到对应分支，不要把两条线混在一起。
（构建时从上游仓库拉取）。因此这里不接受「修改 kkFileView 功能」的 PR ——
那类改动请提到上游：https://github.com/kekingcn/kkFileView

欢迎的改动类型：

* 修复构建、打包、安装脚本中的缺陷
* 改进 CI（GitHub Actions / CNB）的可靠性与速度
* 优化运行时镜像（体积、字体、依赖、安全加固）
* 补充文档与排障经验

## 本地开发约定

1. **换行符必须是 LF**：`.gitattributes` 已强制。脚本在 Linux 容器内执行，
   被检出为 CRLF 会报 `/bin/bash^M: bad interpreter`。
2. **脚本改动后至少过一遍语法检查**：

   ```bash
   for f in *.sh assets/*.sh; do bash -n "$f" || echo "FAIL $f"; done
   ```

3. **本地验证构建链路**（需要本机有 Docker）：

   ```bash
   ./build.sh build            # 编译源码 → dist/
   ./build.sh package          # 打成自包含 tar.gz
   ./build.sh image            # 构建运行时镜像
   ./build.sh smoke            # 起容器 + 探活（4.x 用首页 / ，脚本里也保留了 /actuator/health）
   ```

   没有 Docker 时可用宿主机原生编译（需要 JDK 8 + Maven 3.9+）：

   ```bash
   ./build.sh native
   ```

4. **脚本风格**：`set -euo pipefail`；对外命令失败要给出可执行的下一步提示；
   关键设计要写清「为什么」（例如为什么必须装 LibreOffice）。

## 关于几个容易踩坑的设计

* **编译镜像不装 LibreOffice**：kkFileView 的 `OfficePluginManager` 是
  `@PostConstruct`，找不到 `office.home` 会抛异常让进程直接退出。因此冒烟测试
  只能放在装了 LibreOffice 的运行时镜像里做（`smoke-test.sh`）。
* **最终 tar.gz 由 `package-dist.sh` 生成，而不是编译脚本**：编译发生在 builder
  镜像里，镜像内只有 `build-kkfileview.sh` 一个文件；而打包需要仓库里的
  `install.sh` 与 `assets/`，所以拆成两步。
* **Maven 镜像只镜像 `central`**：kkFileView 依赖 `aspose-cad`（来自
  `https://repository.aspose.com/repo`），用 `<mirrorOf>*</mirrorOf>` 会把它也
  劫持到中央仓库导致解析失败。
* **CNB 的 `runner` / `docker` / `services` 只能写在流水线级别**，stage 级别只支持
  `image`；`.cnb.yml` 里用 YAML 锚点复用。
* **CNB 的 `tag_push` 不要用兜底符 `$`**：滚动发布会创建 `latest` 这个 git tag，
  用 `$` 会把它一起匹配进来，触发多余的完整构建。

## 提交 PR

1. 从最新默认分支切一个分支
2. 按上面的约定自测（脚本语法 + 至少 `./build.sh build` 或 `./build.sh native`）
3. PR 描述里写清：改了什么、为什么、怎么验证的

CI 是最终判据：GitHub Actions 会跑「编译 → 打包 → 构建镜像 → 冒烟测试 → 发布」，
CNB 会跑「编译 → 打包 → 发布 Release → 推送镜像」。
