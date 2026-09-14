# kkfile-build

**kkFileView 的源码编译与打包流水线**：在 Docker 里从上游源码编译出 kkFileView，
产出自包含发行包（tar.gz）与开箱即用的容器镜像，并同时支持 **GitHub Actions** 与
**CNB（cnb.cool）** 两套 CI，任意一端推送即可自动构建、发布。

> 本仓库**不包含** kkFileView 源码。构建时按版本拉取上游 tag 再编译，
> 因此产物永远对应一个明确的源码 commit（记录在 `BUILD-INFO.txt` 里）。
> 上游项目：https://github.com/kekingcn/kkFileView （Apache-2.0）

## 分支与支持的版本

| 分支 | 版本线 | JDK | 说明 |
| --- | --- | --- | --- |
| `main` | 5.x（当前 5.0.2） | 21 | Spring Boot 3.5，有 actuator |
| **`4.x`（本分支）** | 4.4.0 / 4.3.0 / 4.2.1 / 4.2.0 / 4.1.0 | 8 | Spring Boot 2.4.2，**无 actuator** |

两条版本线的构建体系差异较大（JDK、启动探活方式、发布标签），因此分开维护：

* 主线（本分支的 push）滚动发布到 Release `latest-4.x`，镜像打 `latest-4.x` 与 `<版本>`；
  5.x 线用 `latest`，两者互不覆盖
* 稳定版打 tag `v4.4.0` 等，发布到同名 Release
* 想构建 4.x 里的**其他版本**：`./build.sh all 4.3.0`，或在 GitHub Actions 手动触发时
  从下拉框选 4.3.0 / 4.2.1 / 4.2.0 / 4.1.0（CNB 上改 `.cnb.yml` 的 `KK_VERSION`）

---

## 目录

- [产物是什么](#产物是什么)
- [快速开始](#快速开始)
- [从源码构建](#从源码构建)
- [CI：GitHub Actions](#ci-github-actions)
- [CI：CNB](#ci-cnb)
- [配置项](#配置项)
- [架构与已知限制](#架构与已知限制)
- [目录结构](#目录结构)
- [排障](#排障)
- [许可证](#许可证)

---

## 产物是什么

一次构建会产出两样东西：

### 1. 自包含发行包（离线安装）

| 文件 | 说明 |
| --- | --- |
| `kkfileview-<版本>.tar.gz` | 解包目录 `kkFileView-<版本>/`，内置 `install.sh` 与 systemd 服务文件，可离线一键安装 / 原地升级 |
| `kkFileView-<版本>.jar` | 原始 Spring Boot fat jar，供自行集成 |
| `SHA256SUMS` | 校验和 |
| `BUILD-INFO.txt` | 版本、源码仓库与 commit、构建时间、JDK/Maven 版本、jar 校验和 |

发行包解包后的结构：

```
kkFileView-4.4.0/
├── bin/                      # 启动脚本 + kkFileView-4.4.0.jar
│   ├── kkfileview-run.sh     # 前台启动包装脚本（systemd ExecStart 用）
│   ├── startup.sh / shutdown.sh / showlog.sh / dev.sh / install.sh
│   └── kkFileView-4.4.0.jar
├── config/application.properties   # 全部配置项都支持 KK_* 环境变量覆盖
├── log/
├── install.sh                # 本项目的离线安装脚本
├── kkfileview.service        # systemd 模板
├── kkfileview.env.example    # 环境变量样例
├── LICENSE                   # 本项目（MIT）
├── LICENSE.kkfileview.txt    # 上游 kkFileView（Apache-2.0）
└── BUILD-INFO.txt
```

### 2. 容器镜像

Ubuntu 24.04 + OpenJDK 8 + LibreOffice（`libreoffice-nogui`）+ 中文字体
（文泉驿 / Noto CJK）+ 时区 `Asia/Shanghai` + locale `zh_CN.UTF-8`，
以非 root 用户（uid 10001）运行，内置 `HEALTHCHECK`（4.x 无 actuator，探活用首页 `/`）。

| 来源 | 镜像地址 | 架构 |
| --- | --- | --- |
| GitHub Actions | `ghcr.io/jackch3n/kkfile-build:<版本>`（主线另有 `:latest-4.x`） | `linux/amd64`（可选含 `linux/arm64`） |
| CNB | `docker.cnb.cool/jackch3n/kkfile-build:<版本>`（主线另有 `:latest-4.x`） | `linux/amd64` + `linux/arm64` |

---

## 快速开始

### Docker 单机运行

```bash
docker run -d --name kkfileview \
  -p 8012:8012 \
  -v kkfileview-data:/data \
  ghcr.io/jackch3n/kkfile-build:latest-4.x

# 打开 http://127.0.0.1:8012/
curl -fsS -o /dev/null -w '%{http_code}
' http://127.0.0.1:8012/   # 200 即就绪
```

### docker compose

```bash
# 默认使用本地构建的镜像 kkfileview:latest
./build.sh all && docker compose up -d

# 使用 CI 发布的镜像（换成你的仓库地址）
KK_IMAGE=ghcr.io/jackch3n/kkfile-build:latest-4.x docker compose up -d
KK_IMAGE=docker.cnb.cool/jackch3n/kkfile-build:latest-4.x docker compose up -d
```

### 离线安装（裸机 / 内网）

```bash
tar -xzf kkfileview-4.4.0.tar.gz
cd kkFileView-4.4.0

# 先自检（不需要 root，不改动系统）
./install.sh --check

# 安装为 systemd 服务并启动
sudo ./install.sh --start

systemctl status kkfileview
journalctl -u kkfileview -f
```

也可以直接从压缩包安装：

```bash
sudo ./install.sh --from /path/to/kkfileview-4.4.0.tar.gz --start
```

`install.sh` 常用参数：

| 参数 | 说明 |
| --- | --- |
| `--check` | 只做环境自检（Java / LibreOffice / 路径），不改动系统，不需要 root；缺必需组件时以非 0 退出 |
| `--prefix DIR` | 安装目录（默认 `/opt/kkfileview`） |
| `--data-dir DIR` | 转换文件与预览文件目录（默认 `/var/lib/kkfileview`） |
| `--user NAME` | 运行用户（默认 `kkfileview`） |
| `--port N` | 服务端口（默认 `8012`） |
| `--java-home DIR` | 指定 JDK 8（默认自动探测 `JAVA_HOME` / `PATH` / `/usr/lib/jvm`） |
| `--install-office` | 未检测到 LibreOffice 时调用包内 `bin/install.sh` 联网安装 |
| `--no-service` | 只装文件，不创建 systemd 服务 |
| `--force` | `--prefix` 指向的目录非空且不像 kkFileView 安装目录时，允许强行覆盖 |
| `--uninstall [--purge]` | 卸载（默认保留数据目录；`--purge` 一并删除） |

> **前置条件**：JDK 8+ 与 LibreOffice 缺一不可。
> `apt-get install -y openjdk-8-jre libreoffice-nogui fonts-wqy-microhei fonts-wqy-zenhei`

---

## 从源码构建

### 前置条件

* Docker（本地构建镜像用）；或 JDK 8 + Maven 3.9+（`native` 模式）
* 代码里已把 Maven 源、APT 源都做成可配置项，国内网络无需改脚本

### 常用命令

```bash
./build.sh build  [版本] [ref]     # 编译源码 → dist/kkFileView-<版本>/
./build.sh package                 # 打成自包含 tar.gz + SHA256SUMS
./build.sh image  [版本] [平台]     # 构建运行时镜像 kkfileview:<版本>
./build.sh all    [版本]            # 编译 + 打包 + 构建镜像
./build.sh smoke  [镜像tag]         # 冒烟测试（起容器 + 探活）
./build.sh push   <镜像tag> ...     # 推送镜像
./build.sh native [版本] [mirror]   # 宿主机原生编译，不依赖 Docker
./build.sh shell                    # 进编译镜像交互式排障
```

示例：

```bash
./build.sh all                        # 默认 4.4.0，全流程
./build.sh build 5.0.1 v5.0.1         # 指定版本与 git ref
./build.sh image 4.4.0 linux/amd64    # 只构建 amd64 镜像
./build.sh native 4.4.0 central       # 用 Maven 中央仓库原生编译
```

### 只用编译镜像

编译镜像里就是「Maven 3.9 + Temurin JDK 8 + git」，可以单独用：

```bash
docker build -t kkfileview-builder:local -f Dockerfile .
docker run --rm \
  -v "$PWD/dist:/opt/dist" \
  -v "$HOME/.m2:/root/.m2" \
  kkfileview-builder:local \
  --version 4.4.0 --output /opt/dist
```

`build-kkfileview.sh` 主要参数：

| 参数 | 说明 |
| --- | --- |
| `--version VER` | 版本号（如 `4.4.0`），默认据此推导 git tag `v4.4.0` |
| `--ref REF` | 显式指定 git ref（tag / 分支 / commit），优先级高于 `--version` |
| `--repo-url URLS` | 候选源码地址，空格或逗号分隔，按序尝试（默认 GitHub + Gitee 双源） |
| `--maven-mirror NAME` | `aliyun`(默认) / `central` / `huawei` / `tencent` / `none` / 自定义 URL |
| `--output DIR` | 产物目录（默认 `$PWD/dist`） |
| `--jobs N` | Maven `-T N` 并行编译 |
| `--offline-src DIR` | 直接用已有源码目录，跳过克隆 |
| `--no-verify` | 跳过编译后的静态校验（jar 完整性、`ServerMain.class`、依赖是否打全） |

### 构建期做了什么校验

1. **工具链检查**：JDK ≥ 21（项目 `maven.compiler.release=21`）
2. **版本一致性**：`--version` 与源码 `pom.xml` 版本不一致直接报错，
   避免产出「文件名写 4.4.0、里面其实是别的版本」
3. **静态校验**：`unzip -t` 校验 jar 完整性、确认 `BOOT-INF/classes/cn/keking/ServerMain.class`
   与 `BOOT-INF/lib/` 存在、jar 体积下限
4. **运行时冒烟测试**（`build.sh smoke` / CI）：起容器并探活 —— 4.x 没有 actuator
   依赖，用首页 `/`（HTTP 2xx）作为就绪判据（`HEALTH_PATHS` 里也保留了
   `/actuator/health`，便于同一个脚本兼容 5.x），并打印日志里的「服务启动完成」作为佐证

---

## CI：GitHub Actions

工作流：`.github/workflows/build.yml`

### 触发与版本语义

| 触发 | 场景 | 源码 ref | Release tag | 镜像 tag | 平台 |
| --- | --- | --- | --- | --- | --- |
| push 本分支（`4.x`） | 主线 | `v<KK_VERSION>` | `latest-4.x`（滚动更新） | `<版本>`、`v<版本>`、`latest-4.x` | `linux/amd64,linux/arm64` |
| push tag `v*` | 稳定版 | 该 tag | 同名 tag（固化） | `<版本>`、`v<版本>` | `linux/amd64,linux/arm64` |
| `workflow_dispatch` | 手动 | 可指定 | `v<版本>` 或指定 ref | `<版本>`、`v<版本>` | 可选 |

任务链：`prepare` 解析场景 → `build` 编译并打包（同时上传 artifact）→
`image` 构建并推送 GHCR → `smoke` 拉取刚推送的镜像起容器探活；
`release` 与 `image` 并行，负责把发行包发到 GitHub Releases。

`KK_VERSION` 在 workflow 的 `env` 里（默认 `4.4.0`）。**主线也固定从
`v<KK_VERSION>` 这个 tag 取源码**，保证「同一个版本号永远编译同一份代码」；
上游发布新版本时改这一个变量即可。

### 需要的配置

* 无需额外配置：用内置 `GITHUB_TOKEN` 推 GHCR、发 Release（workflow 已声明
  `permissions: contents: write, packages: write`）
* 首次发布后，到仓库 Packages 里把镜像可见性改成 public（如需公开）
* **可选**：把镜像同步到 CNB 制品库，配置
  * Secret `CNB_TOKEN`：CNB 访问令牌
  * Variable `CNB_REPO_SLUG`：形如 `group/repo`

  两个都配好后，镜像会用 `docker buildx imagetools` 跨仓库搬运 manifest 同步到
  `docker.cnb.cool/jackch3n/kkfile-build`（不重复拉取镜像层）

### 手动触发

Actions → build-kkfileview → Run workflow，可指定：

* `version`：kkFileView 版本（同时决定源码 tag）
* `ref`：git ref（留空 = `v<version>`；可填 `master`、`v5.0.1`、commit）
* `platforms`：`linux/amd64` 或 `linux/amd64,linux/arm64`
  （**只构建 amd64 可显著缩短时间**，arm64 需要在 QEMU 下 apt 装 LibreOffice）
* `push_image`：是否构建并推送镜像

---

## CI：CNB

流水线：`.cnb.yml`

### 触发与版本语义

| 触发 | 场景 | 源码 ref | Release tag | 镜像 tag |
| --- | --- | --- | --- | --- |
| push 本分支（`4.x`） | 主线 | `v<KK_VERSION>` | `latest-4.x`（滚动更新） | `<版本>`、`latest-4.x`（多架构） |
| push tag `v*` | 稳定版 | 该 tag | 同名 tag | `<版本>`、`<tag>`（多架构） |

每次触发会起**两条并行流水线**（amd64 / arm64 各一条），共用的阶段链是：
`resolve-scene → build-kkfileview → list-and-check → package-dist →
gen-notes → ensure-release → upload-attachments → push-image-arch → merge-manifest → summary`，
其中 `gen-notes / ensure-release / upload-attachments` 只在 amd64 流水线执行（带 stage 级 `if`）。

* 编译环境用流水线级 `docker.build`（引用本仓库 `Dockerfile`），由 CNB 负责构建缓存，
  所以每个 stage 都直接跑在「Maven + JDK」镜像里
* Release 用 CNB REST API 幂等创建（并发/重跑安全），附件用 `cnbcool/attachments`
* 镜像推送到 CNB 制品库，`services: docker` 注入的 dind 已自动登录，无需配置密钥

### 镜像为什么是双架构、怎么合的

CNB 侧用**两条并行流水线**分别跑 `cnb:arch:amd64` 与 `cnb:arch:arm64:v8` runner：
各自原生编译、原生构建本架构镜像并推 `:<版本>-amd64` / `:<版本>-arm64`，
然后由先看到对方架构的那条流水线用 `docker buildx imagetools create`
把两个架构合并成 `:<版本>` / `:latest` 多架构 manifest（幂等，谁先合都一样）。

不用「一条流水线 + QEMU 多架构 buildx」的原因：QEMU 下 apt 安装 LibreOffice 要
20~40 分钟，而在 dind 里跑 `docker-container` 驱动的多架构 buildx 还依赖
privileged/binfmt，稳定性没保证。两条原生流水线并行只要约 10 分钟，且是原生镜像。

如果 arm64 那条流水线失败，amd64 流水线等待 30 分钟后会退化为发布单架构镜像并给出
警告（不会让流水线变红）；arm64 恢复后下一次构建会自动重新合并。

来源包（tar.gz/jar）与 Release 附件只由 amd64 流水线发布一次 —— 编译产物与架构无关，
避免两条流水线抢同一个 Release。

> 若所在 CNB 环境不支持 dind（`push-image` 阶段报找不到 docker 或无法连接守护进程），
> 把 `.cnb.yml` 里最后的 `push-image` 阶段整段删掉即可：发行包与 Release 照常发布，
> 镜像交给 GitHub Actions 或本机 `./build.sh all` 产出。

---

## 把项目放到你的仓库（GitHub / CNB）

本仓库同时托管在两处，推送时会分别触发两端流水线：

| 平台 | 地址 | 作用 |
| --- | --- | --- |
| GitHub | https://github.com/JackCh3n/kkfile-build | 多架构镜像 → GHCR、冒烟测试、Release |
| CNB | https://cnb.cool/jackch3n/kkfile-build | 国内可直连的 Release 附件 + 镜像 |

日常推送（`origin` = GitHub，`cnb` = CNB）：

```bash
git push origin 4.x         # 触发 GitHub Actions
git push cnb 4.x            # 触发 CNB 流水线
# 一次推两端也可以：
git remote add origin https://github.com/JackCh3n/kkfile-build.git
git remote add cnb    https://cnb.cool/jackch3n/kkfile-build.git
```

### GitHub 侧

* 推送 `4.x` 分支即触发 `.github/workflows/build.yml`，无需额外配置
  （workflow 已声明 `permissions: contents: write, packages: write`）
* 镜像地址为 `ghcr.io/jackch3n/kkfile-build`（镜像名与本仓库同名）；
  首次发布后到仓库的 Packages 页面把镜像可见性改成 public（如需公开）
* 可选：加 Variable `CNB_REPO_SLUG`（本仓库即 `jackch3n/kkfile-build`）与
  Secret `CNB_TOKEN`，即可把镜像同步到 CNB 制品库

### CNB 侧

* 推送代码后，平台会自动读取 `.cnb.yml` 并执行，
  无需配置任何密钥（`CNB_TOKEN` 由平台注入）
* 推送 `4.x` 分支触发主线，推送 tag `v*` 触发稳定版
* 镜像地址为 `docker.cnb.cool/jackch3n/kkfile-build`

### 发布一个稳定版

```bash
git tag v4.4.0
git push origin v4.4.0
```

### 跟随上游升级版本

改两个地方（保持两者一致），然后 push 到 `main`：

| 文件 | 变量 |
| --- | --- |
| `.github/workflows/build.yml` | `env.KK_VERSION` |
| `.cnb.yml` | `.vars.KK_VERSION` |

也可以不改代码，用 GitHub 的 `workflow_dispatch` 手动指定 `version` / `ref` 试构建。
源码会从 `v<KK_VERSION>` 这个 tag 拉取，所以**上游必须存在同名 tag**；
上游还没打 tag 时，可以手动触发并填 `ref`（例如 `master`）。

---

## 配置项

`config/application.properties` 里所有配置项都写成 `${KK_XXX:默认值}`，
因此**都可以用环境变量覆盖**（Docker 用 `-e`，systemd 用 `/etc/kkfileview/kkfileview.env`）。

常用项：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KK_SERVER_PORT` | `8012` | 服务端口 |
| `KK_CONTEXT_PATH` | `/` | 上下文路径（改了健康检查路径也要跟着改） |
| `KK_OFFICE_HOME` | `default` | LibreOffice 安装路径，`default` 表示自动查找 |
| `KK_FILE_DIR` | `<安装目录>/file` | 转换后文件存放目录（**需要可写、空间充足**） |
| `KK_LOCAL_PREVIEW_DIR` | 同 `KK_FILE_DIR` | 本地预览文件目录 |
| `KK_TRUST_HOST` | `default` | 信任站点白名单，逗号分隔；`default` 表示仅本机测试 |
| `KK_OFFICE_PREVIEW_TYPE` | `image` | Office 预览模式：`image` / `pdf`（4.x 默认是 image） |
| `KK_OFFICE_PREVIEW_SWITCH_DISABLED` | `true` | 是否禁止前端切换预览模式 |
| `KK_MEDIA` / `KK_CONVERTMEDIAS` | 见配置 | 直接预览 / 需要转码的媒体格式清单 |
| `KK_MEDIA_CONVERT_DISABLE` | `false` | 是否关闭音视频转码 |
| `KK_BASE_URL` | — | 对外访问地址（反向代理场景建议显式配置） |
| `KK_CACHE_ENABLED` / `KK_CACHE_TYPE` / `KK_CACHE_CLEAN_*` | — | 缓存与定时清理 |
| `KK_SPRING_REDISSON_ADDRESS` / `..._PASSWORD` | — | Redis（Redisson）相关 |
| `KK_PDF_PRINT_DISABLE` / `KK_PDF_DOWNLOAD_DISABLE` / `KK_PDF_BOOKMARK_DISABLE` 等 | 见配置 | PDF 预览开关 |
| `KK_TIF_PREVIEW_TYPE` / `KK_SIMTEXT` / `KK_FTP_*` | 见配置 | 其他版本差异项 |

> **各小版本的可配项并不完全一致**（例如 4.1.0 的文件上传开关是
> `KK_FILE_UPLOAD_ENABLED`，4.2 起改为 `KK_FILE_UPLOAD_DISABLE`；
> `KK_PROHIBIT`、`KK_CAD_*`、`KK_OFFICE_WATERMARK`、`KK_NOT_TRUST_HOST`
> 是 4.3/4.4 才有的）。**以你实际构建的那个版本的
> `config/application.properties` 为准**：解包后 `grep KK_ config/application.properties`。

另外 `JAVA_OPTS` 控制 JVM 参数（默认 `-Xms512m -Xmx2g`），内存要按并发量与
文档大小调整：大文件转 PDF 是内存消耗大头。

> **安全提醒**：镜像/发行包默认 `trust.host=default`（仅本机测试）。生产环境请务必
> 配置 `KK_TRUST_HOST`，否则外部文件预览请求会被拒绝或存在 SSRF 风险。

---

## 架构与已知限制

### 默认 amd64，arm64 可选

* `linux/amd64`：功能完整
* `linux/arm64`：**视频转码类预览不可用**。上游 JavaCV 依赖的 ffmpeg / opencv /
  openblas 原生库只声明了 `linux-x86_64` 与 `windows-x86_64` classifier，
  arm64 下没有对应 `.so`，`avi/mov/rmvb/wmv/mkv` 等需要转码的格式会失败；
  Office / PDF / 图片 / CAD / 压缩包 / 文本等主要能力不受影响
* 上游官方镜像同样提供 arm64，所以这里默认也带上 arm64；如果你只需要稳定可用的
  子集，把 CI 的 `platforms` 改成 `linux/amd64` 即可（构建时间也大幅缩短）

### 必须装 LibreOffice

kkFileView 的 `OfficePluginManager.startOfficeManager()` 是 `@PostConstruct`，
`office.home` 找不到会直接抛 `RuntimeException` 让进程退出——**不是**「降级可用」，
而是起不来。所以：

* 运行时镜像里已内置 `libreoffice-nogui`（Ubuntu 装在 `/usr/lib/libreoffice`，
  正好命中 `LocalOfficeUtils` 的默认搜索路径，`office.home=default` 即可）
* 裸机安装请先 `apt-get install -y libreoffice-nogui`

### 中文字体

镜像内置文泉驿（微米黑 / 正黑）与 Noto CJK。若文档使用特殊字体（宋体、仿宋、
方正系列等），转换后可能排版错位。把字体文件放进 `assets/fonts/` 后重新构建即可
（详见 `assets/fonts/README.md`）。请留意字体的授权许可。

### 其他

* 首次启动约需 10~60 秒（Spring 上下文 + LibreOffice 拉起），`HEALTHCHECK`
  `start-period` 已设为 120s
* LibreOffice 会 fork 子进程，容器停止给了 90s 优雅退出时间
  （`stop_grace_period` / systemd `TimeoutStopSec`），请不要强杀

---

## 目录结构

```
kkfile-build/
├── Dockerfile                  # 编译镜像（Maven 3.9 + JDK 8 + git）
├── Dockerfile.runtime          # 运行时镜像（Ubuntu 24.04 + JRE 8 + LibreOffice + 中文字体）
├── Dockerfile.dockerignore     # 编译镜像专用的上下文白名单（只传编译脚本）
├── .dockerignore
├── build.sh                    # 宿主机一键入口
├── build-kkfileview.sh         # 取源码 → Maven 编译 → 解包 → 静态校验
├── package-dist.sh             # 注入 install.sh/assets → 打 tar.gz + 校验和
├── smoke-test.sh               # 运行时镜像冒烟测试（起容器 + 探活）
├── install.sh                  # 离线安装 / 原地升级 + systemd
├── docker-compose.yml
├── assets/
│   ├── kkfileview-run.sh       # 前台启动包装（Docker ENTRYPOINT 与 systemd 共用）
│   ├── kkfileview.service      # systemd 模板
│   ├── kkfileview.env.example  # 环境变量样例
│   └── fonts/                  # 放自定义字体（随镜像安装）
├── .github/workflows/build.yml # GitHub Actions：编译 → 镜像 → 冒烟 → Release
├── .cnb.yml                    # CNB：编译 → Release → 镜像
├── LICENSE / CONTRIBUTING.md / README.md
```

---

## 排障

**服务起不来，日志报 `找不到office组件，请确认'office.home'配置是否有误`**
没装 LibreOffice。`apt-get install -y libreoffice-nogui`，或确认 `KK_OFFICE_HOME`
指向的目录下存在 `program/soffice.bin`。

**Maven 依赖下载很慢 / 卡在 `repository.aspose.com`**
`aspose-cad` 来自 Aspose 自己的仓库，无法用中央仓库镜像替代。若完全拉不到，
需要自建 Nexus 代理该仓库，再做 `settings.xml` 覆盖（`build-kkfileview.sh` 里生成的
镜像只作用于 `central`，不会劫持 aspose 仓库）。

**编译老是被 Docker Hub 限流 / 拉不到基础镜像**
`maven:3.9-eclipse-temurin-21`、`ubuntu:24.04` 都可换成国内镜像地址：

```bash
docker build --build-arg BUILDER_IMAGE=<registry>/maven:3.9-eclipse-temurin-21 -f Dockerfile .
docker build --build-arg RUNTIME_BASE=<registry>/ubuntu:24.04 -f Dockerfile.runtime ... .
```

**镜像里中文文档乱码**
确认使用本项目构建的镜像（内置中文字体），并把文档里用到的字体放进
`assets/fonts/` 重新构建。

**磁盘被转换文件吃满**
转换后的文件在 `KK_FILE_DIR`。容器部署挂 `-v <host>:/data`，裸机部署把
`KK_FILE_DIR` 指到大盘（默认 `/var/lib/kkfileview/file`）。清理任务由
`KK_CACHE_CLEAN_CRON` 控制。

**转换大文件时内存溢出**
调大 `JAVA_OPTS` 的 `-Xmx`（Docker 用 `-e JAVA_OPTS=...`，systemd 改
`/etc/kkfileview/kkfileview.env`），同时注意容器内存上限。

**想确认产物对应哪次源码提交**
看发行包里的 `BUILD-INFO.txt`：包含源码仓库、ref、commit、构建时间、
JDK/Maven 版本与 jar 校验和。

---

## 许可证

* 本仓库（构建与打包工具链）：MIT，见 [LICENSE](LICENSE)
* 上游 kkFileView：Apache-2.0，见 https://github.com/kekingcn/kkFileView
  发行包与镜像内含上游代码，发行包内附带 `LICENSE.kkfileview.txt`

本仓库不修改 kkFileView 源码，仅做编译与打包。功能问题请提到上游。
