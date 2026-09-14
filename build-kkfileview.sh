#!/usr/bin/env bash
# =============================================================================
# build-kkfileview.sh —— 从源码编译 kkFileView
#
# 既可以在编译镜像（Dockerfile）里作为入口运行，也可以在宿主机上直接运行
# （宿主机需自备 git / JDK 8 / Maven 3.9+）。
#
# 产物（--output 指定，默认 $PWD/dist）：
#   <out>/kkFileView-<版本>/                 解包后的发行目录（bin/ config/ log/ …）
#   <out>/kkFileView-<版本>.jar              原始 Spring Boot fat jar
#   <out>/BUILD-INFO.txt                     构建元信息（版本 / commit / 工具链 / 校验和）
#   <out>/LICENSE.kkfileview.txt             上游 Apache-2.0 许可证原文
#
# 职责边界：本脚本只做「取源码 → 编译 → 解包 → 静态校验」。
# 安装脚本 / systemd 服务 / 最终自包含 tar.gz 由 package-dist.sh 负责，
# 因为它需要仓库里的 assets/ 与 install.sh —— 而编译镜像里并没有这些文件。
#
# 用法示例：
#   build-kkfileview.sh --version 4.4.0 --output /opt/dist
#   build-kkfileview.sh --ref master  --maven-mirror central
#   build-kkfileview.sh --offline-src /opt/src/kkFileView --output ./dist
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.0.0"
# 4.x 线默认构建最新的 4.x（上游 tag v4.4.0）
DEFAULT_VERSION="4.4.0"
# 默认源码地址（按顺序尝试，任一可用即继续）：CNB/国内网络优先走 Gitee 镜像
DEFAULT_REPO_URLS="https://github.com/kekingcn/kkFileView.git https://gitee.com/kekingcn/file-online-preview.git"

# ---------- 可覆盖参数 ----------
OPT_VERSION="${KK_VERSION:-$DEFAULT_VERSION}"
OPT_REF="${KK_REF:-}"
OPT_REPO_URLS="${KK_REPO_URLS:-$DEFAULT_REPO_URLS}"
OPT_MAVEN_MIRROR="${MAVEN_MIRROR:-aliyun}"
OPT_OUTPUT=""
OPT_WORK_DIR="${KK_WORK_DIR:-${TMPDIR:-/tmp}/kkfileview-build}"
OPT_JOBS="${KK_JOBS:-1}"
OPT_OFFLINE_SRC="${KK_OFFLINE_SRC:-}"
OPT_VERIFY="yes"
OPT_KEEP_SRC="no"
OPT_ALLOW_MISMATCH="no"
# 编译所需的最小 JDK 版本：4.x 线的项目是 Java 8（maven.compiler.source/target=1.8），
# 必须用 JDK 8 编译；main 分支（5.x）则是 21
MIN_JAVA_MAJOR="${MIN_JAVA_MAJOR:-8}"

# ---------- 运行期状态 ----------
SRC_DIR=""
SRC_URL=""
SRC_COMMIT=""
SRC_COMMIT_DATE=""
ARTIFACT_VERSION=""     # 以 pom.xml 为准的真实版本
PKG_DIR=""              # 解包后的发行目录（由 collect_and_verify 写入）
MVN_SETTINGS=""

# ---------- 基础工具函数 ----------
log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
从源码编译 kkFileView（产出解包后的发行目录，供 package-dist.sh 打包）

用法：
  build-kkfileview.sh [选项]

选项：
  --version VER        kkFileView 版本，如 4.4.0；也可传 main/master 等分支名
                       （默认 4.4.0，可用环境变量 KK_VERSION 覆盖）
  --ref REF            git ref（tag / 分支 / commit），显式指定时优先级高于 --version
  --repo-url URLS      候选源码地址，空格或逗号分隔，按顺序尝试
                       （默认 github + gitee 两个官方镜像）
  --maven-mirror NAME  Maven 中央仓库镜像：aliyun(默认)|central|huawei|tencent|none|<自定义URL>
  --output DIR         产物输出目录（默认 $PWD/dist）
  --work-dir DIR       源码克隆目录（默认 $TMPDIR/kkfileview-build）
  --jobs N             Maven 并行线程数（-T N，默认 1 表示不启用）
  --offline-src DIR    直接使用已有的源码目录，跳过克隆
  --no-verify          跳过编译后的静态校验（不推荐）
  --min-java N         编译所需最小 JDK 版本（默认 8；4.x 源码 maven.compiler=1.8）
  --allow-mismatch     允许 --version 与 pom.xml 中的版本号不一致（默认报错）
  --keep-src           保留克隆出来的源码目录
  -h, --help           显示本帮助

环境变量：KK_VERSION / KK_REF / KK_REPO_URLS / MAVEN_MIRROR / KK_WORK_DIR /
          KK_JOBS / KK_OFFLINE_SRC
EOF
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --version)        OPT_VERSION="${2:?--version 需要参数}"; shift 2 ;;
    --ref)            OPT_REF="${2:?--ref 需要参数}"; shift 2 ;;
    --repo-url|--repo-urls)
                      OPT_REPO_URLS="${2:?--repo-url 需要参数}"; shift 2 ;;
    --maven-mirror)   OPT_MAVEN_MIRROR="${2:?--maven-mirror 需要参数}"; shift 2 ;;
    --output)         OPT_OUTPUT="${2:?--output 需要参数}"; shift 2 ;;
    --work-dir)       OPT_WORK_DIR="${2:?--work-dir 需要参数}"; shift 2 ;;
    --jobs)           OPT_JOBS="${2:?--jobs 需要参数}"; shift 2 ;;
    --offline-src)    OPT_OFFLINE_SRC="${2:?--offline-src 需要参数}"; shift 2 ;;
    --no-verify)      OPT_VERIFY="no"; shift ;;
    --min-java)       MIN_JAVA_MAJOR="${2:?--min-java 需要参数}"; shift 2 ;;
    --allow-mismatch) OPT_ALLOW_MISMATCH="yes"; shift ;;
    --keep-src)       OPT_KEEP_SRC="yes"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -n "$OPT_OUTPUT" ] || OPT_OUTPUT="$PWD/dist"
# 允许 --repo-url 用逗号分隔
OPT_REPO_URLS="$(printf '%s' "$OPT_REPO_URLS" | tr ',' ' ')"

# ---------- 工具链检查 ----------
java_major_version() {
  local bin="$1" all first major
  # 先全量捕获再取首行：`java -version | head -n1` 在 set -o pipefail 下，
  # 一旦 head 提前退出给 java 发 SIGPIPE，整个管道就会返回非 0 让脚本中止。
  all="$("$bin" -version 2>&1 || true)"
  first="${all%%$'\n'*}"
  major="$(printf '%s' "$first" | sed -nE 's/.*version "([0-9]+).*/\1/p')"
  if [ "$major" = "1" ]; then
    printf '%s' "$first" | sed -nE 's/.*version "1\.([0-9]+).*/\1/p'
  else
    printf '%s' "$major"
  fi
}

check_toolchain() {
  local missing=""
  command -v git >/dev/null 2>&1 || missing="$missing git"
  command -v mvn >/dev/null 2>&1 || missing="$missing maven"
  command -v java >/dev/null 2>&1 || missing="$missing java(jre)"
  [ -z "$missing" ] || die "缺少必要工具:$missing（编译镜像内已预装，宿主机原生编译请自行安装）"

  local major
  major="$(java_major_version java)"
  case "$major" in
    ''|*[!0-9]*) die "无法识别 java 版本：$(java -version 2>&1 | head -n1)" ;;
  esac
  # 编译所需 JDK 下限：main=21（maven.compiler.release=21），4.x=8
  [ "$major" -ge "$MIN_JAVA_MAJOR" ] || die "需要 JDK ${MIN_JAVA_MAJOR} 或更高版本，当前为 $major（可用 JAVA_HOME 指向 ${MIN_JAVA_MAJOR} 的 JDK）"

  log "工具链: $(java -version 2>&1 | head -n1)"
  log "工具链: $(mvn -v 2>/dev/null | head -n1) / git $(git --version | awk '{print $3}')"
}

# ---------- ref 推导 ----------
resolve_ref() {
  if [ -n "$OPT_REF" ]; then
    printf '%s' "$OPT_REF"; return 0
  fi
  case "$OPT_VERSION" in
    v[0-9]*)          printf '%s' "$OPT_VERSION" ;;   # 已带 v 前缀的 tag
    */*)              printf '%s' "$OPT_VERSION" ;;   # 形如 feature/xxx 的分支
    main|master|trunk|develop|dev) printf '%s' "$OPT_VERSION" ;;
    *)                printf 'v%s' "$OPT_VERSION" ;;
  esac
}

# ---------- 源码获取 ----------
clone_source() {
  local ref="$1" url
  for url in $OPT_REPO_URLS; do
    log "克隆源码: ${url} (ref=${ref})"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    # 首选：浅克隆指定 ref（tag 或分支）
    if git clone --depth 1 --branch "$ref" "$url" "$SRC_DIR" 2>&1 | sed 's/^/    /'; then
      SRC_URL="$url"; break
    fi
    # 回退：ref 是 commit sha 时 --branch 不可用，改用「无 blob 过滤 + 检出」
    warn "浅克隆 ref=${ref} 失败，回退为按 ref 检出"
    rm -rf "$SRC_DIR"
    if git clone --filter=blob:none --no-checkout "$url" "$SRC_DIR" >/dev/null 2>&1 \
       && git -C "$SRC_DIR" checkout --detach "$ref" >/dev/null 2>&1; then
      SRC_URL="$url"; break
    fi
    warn "源码地址不可用: ${url}，尝试下一个"
  done
  [ -n "$SRC_URL" ] || die "所有候选源码地址均不可用: ${OPT_REPO_URLS}"
  log "源码就绪: ${SRC_URL} (ref=${ref})"
}

use_offline_source() {
  [ -d "$OPT_OFFLINE_SRC" ] || die "--offline-src 目录不存在: ${OPT_OFFLINE_SRC}"
  [ -f "$OPT_OFFLINE_SRC/pom.xml" ] || die "--offline-src 目录下没有 pom.xml，不是 kkFileView 源码目录"
  SRC_DIR="$(cd "$OPT_OFFLINE_SRC" && pwd)"
  SRC_URL="(local) ${SRC_DIR}"
  log "使用已有源码目录: ${SRC_DIR}"
}

read_pom_version() {
  # 父 pom 中 <artifactId>kkFileView-parent</artifactId> 紧随其后的第一个 <version>
  local pom="$1/pom.xml"
  [ -f "$pom" ] || die "未找到 $pom"
  awk '
    /<artifactId>kkFileView-parent<\/artifactId>/ { found=1 }
    found && /<version>/ {
      line=$0
      sub(/.*<version>/, "", line)
      sub(/<\/version>.*/, "", line)
      gsub(/[ \t\r\n]/, "", line)
      print line
      exit
    }' "$pom"
}

# ---------- Maven 配置 ----------
mirror_url() {
  case "$1" in
    aliyun)  printf 'https://maven.aliyun.com/repository/central' ;;
    huawei)  printf 'https://repo.huaweicloud.com/repository/maven' ;;
    tencent) printf 'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/' ;;
    central) printf 'https://repo.maven.apache.org/maven2' ;;
    none|"") printf '' ;;
    http*|*) printf '%s' "$1" ;;
  esac
}

write_maven_settings() {
  local url="$1" dir="$2"
  if [ -z "$url" ]; then
    log "Maven 镜像: 不使用镜像（直连中央仓库）"
    MVN_SETTINGS=""
    return 0
  fi
  mkdir -p "$dir"
  MVN_SETTINGS="$dir/settings.xml"
  cat > "$MVN_SETTINGS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>kkfile-build-mirror</id>
      <name>kkfile-build central mirror</name>
      <!-- 只镜像 central：kkFileView 的 aspose-cad 依赖来自
           https://repository.aspose.com/repo，若用 &lt;mirrorOf&gt;*&lt;/mirrorOf&gt;
           把它也劫持到中央仓库会导致依赖解析失败 -->
      <mirrorOf>central</mirrorOf>
      <url>${url}</url>
    </mirror>
  </mirrors>
</settings>
EOF
  log "Maven 镜像: ${OPT_MAVEN_MIRROR} -> ${url}"
  log "Maven 配置: ${MVN_SETTINGS}"
}

run_maven_build() {
  local args=(-B -Dmaven.test.skip=true -Dfile.encoding=UTF-8)
  [ -n "$MVN_SETTINGS" ] && args+=(-s "$MVN_SETTINGS")
  case "$OPT_JOBS" in
    ''|0|1) : ;;
    *) args+=(-T "$OPT_JOBS") ;;
  esac
  log "开始编译: mvn ${args[*]} clean package"
  ( cd "$SRC_DIR" && mvn "${args[@]}" clean package )
}

# ---------- 产物收集与校验 ----------
collect_and_verify() {
  local target="$SRC_DIR/server/target" tarball jar pkg_dir listing
  # 用 sed 取第一行而不是 head（head 提前退出会给 ls 发 SIGPIPE，
  # 在 set -o pipefail 下会让赋值返回非 0，从而误报「未找到发行包」）
  tarball="$(ls -1t "$target"/kkFileView-*.tar.gz 2>/dev/null | sed -n '1p' || true)"
  jar="$(ls -1t "$target"/kkFileView-*.jar 2>/dev/null | sed -n '1p' || true)"
  [ -n "$tarball" ] || die "编译结束但未找到发行包（$target/kkFileView-*.tar.gz）"
  [ -n "$jar" ]     || die "编译结束但未找到 jar（$target/kkFileView-*.jar）"
  log "发行包: $tarball"
  log "jar   : $jar"

  # 解包（发行包内顶层目录为 kkFileView-<版本>）
  pkg_dir="$OPT_OUTPUT/kkFileView-${ARTIFACT_VERSION}"
  rm -rf "$pkg_dir"
  mkdir -p "$OPT_OUTPUT"
  tar -xzf "$tarball" -C "$OPT_OUTPUT"
  [ -d "$pkg_dir" ] || die "解包后未找到目录 $pkg_dir（发行包顶层目录名与 pom 版本不一致？）"
  [ -f "$pkg_dir/config/application.properties" ] || die "发行包缺少 config/application.properties"
  ls -1 "$pkg_dir"/bin/kkFileView-*.jar >/dev/null 2>&1 || die "发行包 bin/ 下缺少 kkFileView-*.jar"

  # 原始 fat jar 单独留一份（方便只想要 jar 的使用方）
  cp -f "$jar" "$OPT_OUTPUT/kkFileView-${ARTIFACT_VERSION}.jar"

  if [ "$OPT_VERIFY" = "yes" ]; then
    log "静态校验..."
    if command -v unzip >/dev/null 2>&1; then
      unzip -tqq "$jar" >/dev/null || die "jar 完整性校验失败（unzip -t）"
      # 注意：这里先把清单读进变量再 grep，不要写成 `unzip -l | grep -q`。
      # grep -q 命中即退出会给 unzip 发 SIGPIPE，在 set -o pipefail 下会让整个
      # 管道返回非 0，导致「明明存在却报找不到」的偶发失败。
      listing="$(unzip -l "$jar")"
      # 用 shell 的 case 做子串匹配，避免 `... | grep -q` 在 pipefail 下因
      # 上游被 SIGPIPE 而误判（grep -q 命中即退出）
      case "$listing" in
        *'BOOT-INF/classes/cn/keking/ServerMain.class'*) ;;
        *) die "jar 内未找到 cn/keking/ServerMain.class，可能不是 Spring Boot 可执行包" ;;
      esac
      case "$listing" in
        *'BOOT-INF/lib/'*) ;;
        *) die "jar 内未找到 BOOT-INF/lib/，依赖未被打包" ;;
      esac
    else
      warn "未安装 unzip，跳过 jar 完整性校验"
    fi
    # fat jar 体积下限（正常在 100MB 以上，含 JavaCV 原生库）
    local size_mb
    size_mb=$(( $(wc -c < "$jar") / 1024 / 1024 ))
    [ "$size_mb" -ge 30 ] || die "jar 体积异常（${size_mb}MB），疑似依赖未打包完整"
    log "jar 体积: ${size_mb}MB，静态校验通过"
  fi
  PKG_DIR="$pkg_dir"
}

# ---------- 构建信息 ----------
write_build_info() {
  local pkg_dir="$1" jar="$OPT_OUTPUT/kkFileView-${ARTIFACT_VERSION}.jar" sha
  sha="$(sha256sum "$jar" | awk '{print $1}')"
  cat > "$OPT_OUTPUT/BUILD-INFO.txt" <<EOF
kkFileView 发行包构建信息
================================================================
项目版本        : ${ARTIFACT_VERSION}
请求版本/ref    : ${OPT_VERSION} / ${OPT_REF_EFFECTIVE}
构建时间(UTC)   : $(date -u '+%Y-%m-%d %H:%M:%S')
源码仓库        : ${SRC_URL}
源码提交        : ${SRC_COMMIT}
提交时间        : ${SRC_COMMIT_DATE}
构建OS          : $(uname -srm)
JDK             : $(java -version 2>&1 | head -n1)
Maven           : $(mvn -v 2>/dev/null | head -n1)
Maven 镜像      : ${OPT_MAVEN_MIRROR}
Maven 命令      : mvn -B -Dmaven.test.skip=true clean package（--offline-src 时为已有源码目录）
发行目录        : $(basename "$pkg_dir")
应用端口        : 8012（可用环境变量 KK_SERVER_PORT 覆盖）
健康检查        : http://127.0.0.1:8012/（首页返回 2xx 即就绪；4.x 无 actuator）
上下文路径      : /（可用环境变量 KK_CONTEXT_PATH 覆盖）
fat jar SHA256  : ${sha}
说明            : kkFileView 启动时强依赖 LibreOffice（office.home），
                  裸机部署请先安装 LibreOffice；容器部署请使用运行时镜像。
================================================================
EOF
  log "构建信息: $OPT_OUTPUT/BUILD-INFO.txt"
}

# ---------- 主流程 ----------
main() {
  log "build-kkfileview.sh v${SCRIPT_VERSION}"
  log "目标版本: ${OPT_VERSION}"

  # 先校验入参，再查工具链，让「路径写错」这类问题第一时间暴露
  if [ -n "$OPT_OFFLINE_SRC" ]; then
    [ -d "$OPT_OFFLINE_SRC" ] || die "--offline-src 目录不存在: ${OPT_OFFLINE_SRC}"
    [ -f "$OPT_OFFLINE_SRC/pom.xml" ] || die "--offline-src 目录下没有 pom.xml，不是 kkFileView 源码目录: ${OPT_OFFLINE_SRC}"
  fi

  check_toolchain

  if [ -n "$OPT_OFFLINE_SRC" ]; then
    use_offline_source
    OPT_REF_EFFECTIVE="(已有源码目录)"
  else
    OPT_REF_EFFECTIVE="$(resolve_ref)"
    SRC_DIR="${OPT_WORK_DIR}/kkFileView"
    mkdir -p "$OPT_WORK_DIR"
    clone_source "$OPT_REF_EFFECTIVE"
    SRC_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    SRC_COMMIT_DATE="$(git -C "$SRC_DIR" log -1 --format='%cI' 2>/dev/null || echo unknown)"
  fi
  [ -n "$SRC_COMMIT" ] || SRC_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  [ -n "$SRC_COMMIT_DATE" ] || SRC_COMMIT_DATE="$(git -C "$SRC_DIR" log -1 --format='%cI' 2>/dev/null || echo unknown)"

  ARTIFACT_VERSION="$(read_pom_version "$SRC_DIR")"
  [ -n "$ARTIFACT_VERSION" ] || die "无法从 pom.xml 解析项目版本"
  log "源码 pom 版本: ${ARTIFACT_VERSION}"

  # 版本一致性校验：用 tag 构建时必须与 pom 一致，避免产物「名不符实」
  if [ "$ARTIFACT_VERSION" != "$OPT_VERSION" ] && [ "$OPT_VERSION" != "main" ] && [ "$OPT_VERSION" != "master" ]; then
    if [ "$OPT_ALLOW_MISMATCH" = "yes" ]; then
      warn "请求版本 ${OPT_VERSION} 与 pom 版本 ${ARTIFACT_VERSION} 不一致（已按 --allow-mismatch 放行，产物以 pom 版本命名）"
    else
      die "请求版本 ${OPT_VERSION} 与源码 pom 版本 ${ARTIFACT_VERSION} 不一致；
    请确认 --version/--ref 是否正确，或加 --allow-mismatch 强行继续"
    fi
  fi

  write_maven_settings "$(mirror_url "$OPT_MAVEN_MIRROR")" "$OPT_WORK_DIR/maven"
  run_maven_build

  collect_and_verify
  local pkg_dir="$PKG_DIR"

  # 上游许可证随产物分发（Apache-2.0 要求保留版权与许可声明）
  local lic
  for lic in LICENSE LICENSE.txt; do
    if [ -f "$SRC_DIR/$lic" ]; then
      cp -f "$SRC_DIR/$lic" "$OPT_OUTPUT/LICENSE.kkfileview.txt"
      break
    fi
  done
  [ -f "$OPT_OUTPUT/LICENSE.kkfileview.txt" ] || warn "未在源码中找到上游 LICENSE 文件"

  write_build_info "$pkg_dir"

  if [ "$OPT_KEEP_SRC" != "yes" ] && [ -z "$OPT_OFFLINE_SRC" ]; then
    rm -rf "$SRC_DIR"
  fi

  log "编译完成，产物目录: $OPT_OUTPUT"
  ls -lh "$OPT_OUTPUT"
}

main "$@"
