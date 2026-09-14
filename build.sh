#!/usr/bin/env bash
# =============================================================================
# build.sh —— 宿主机一键入口（本机已安装 Docker 时使用）
#
# 用法：
#   ./build.sh build  [版本] [ref]            # 编译源码 → dist/（含解包目录）
#   ./build.sh package                        # 只打包 dist/（生成 tar.gz + 校验和）
#   ./build.sh image  [版本] [平台]            # 构建运行时镜像（会自动先 build + package）
#   ./build.sh all    [版本]                   # 编译 + 打包 + 构建镜像
#   ./build.sh smoke  [镜像tag]                # 冒烟测试运行时镜像
#   ./build.sh push   <镜像tag> [更多tag...]    # 推送镜像（需先 docker login）
#   ./build.sh native [版本] [mirror]          # 宿主机原生编译（需 JDK 8 + Maven 3.9+）
#   ./build.sh shell                           # 进入编译镜像的交互式 shell（排障用）
#
# 示例：
#   ./build.sh all                       # 默认版本 4.4.0，产出 dist/ 与 kkfileview:4.4.0
#   ./build.sh build 4.4.0 v4.4.0        # 指定版本与 git ref
#   ./build.sh image 4.4.0 linux/amd64   # 只构建 amd64 镜像
#   ./build.sh smoke kkfileview:4.4.0
#
# 环境变量：
#   KK_VERSION      默认版本（默认 4.4.0）
#   KK_REPO_URLS    候选源码地址，空格分隔
#   MAVEN_MIRROR    aliyun(默认)|central|huawei|tencent|none|<url>
#   DOCKER_BUILDKIT 默认 1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DIST_DIR="${SCRIPT_DIR}/dist"
BUILDER_IMAGE="kkfileview-builder:local"
RUNTIME_IMAGE="kkfileview"
DEFAULT_VERSION="${KK_VERSION:-4.4.0}"
DEFAULT_REPO_URLS="https://github.com/kekingcn/kkFileView.git https://gitee.com/kekingcn/file-online-preview.git"

export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: ./build.sh <命令> [参数]

命令:
  build   [版本] [ref]             编译源码 → dist/kkFileView-<版本>/
  package                          把 dist/ 打成自包含 tar.gz + SHA256SUMS
  image   [版本] [平台]             构建运行时镜像（自动确保 dist 已就绪）
  all     [版本]                    编译 + 打包 + 构建镜像
  smoke   [镜像tag]                 冒烟测试运行时镜像（起容器 + 探活）
  push    <镜像tag> [更多tag...]     推送镜像到仓库
  native  [版本] [mirror]           宿主机原生编译（不依赖 Docker）
  shell                            进入编译镜像交互式 shell（排障）

环境变量: KK_VERSION / KK_REPO_URLS / MAVEN_MIRROR
EOF
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"
  docker info >/dev/null 2>&1 || die "Docker 守护进程不可用（docker info 失败）"
}

# 容器内以 root 写的 dist/，回收属主，避免后续非 root 操作（tar/打包）失败
reclaim_dist_owner() {
  [ -d "$DIST_DIR" ] || return 0
  if [ "$(id -u)" = "0" ]; then
    chown -R "$(id -u):$(id -g)" "$DIST_DIR" 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n chown -R "$(id -u):$(id -g)" "$DIST_DIR" 2>/dev/null || true
  fi
  chmod -R a+rX "$DIST_DIR" 2>/dev/null || true
}

build_builder_image() {
  need_docker
  log "构建编译镜像: ${BUILDER_IMAGE}"
  docker build -t "$BUILDER_IMAGE" -f Dockerfile "$SCRIPT_DIR"
}

do_build() {
  local ver="${1:-$DEFAULT_VERSION}" ref="${2:-}"
  need_docker
  mkdir -p "$DIST_DIR" "$HOME/.m2"
  build_builder_image

  log "编译 kkFileView ${ver}${ref:+（ref=${ref}）}"
  local args=(--version "$ver"
              --maven-mirror "${MAVEN_MIRROR:-aliyun}"
              --repo-url "${KK_REPO_URLS:-$DEFAULT_REPO_URLS}"
              --output /opt/dist)
  [ -n "$ref" ] && args+=(--ref "$ref")

  docker run --rm \
    -v "$HOME/.m2:/root/.m2" \
    -v "$DIST_DIR:/opt/dist" \
    "$BUILDER_IMAGE" "${args[@]}"

  reclaim_dist_owner
  log "编译产物:"
  ls -lh "$DIST_DIR" 2>/dev/null || true
}

do_package() {
  log "打包自包含发行包"
  bash "$SCRIPT_DIR/package-dist.sh" --dist "$DIST_DIR"
}

do_image() {
  local ver="${1:-$DEFAULT_VERSION}" platform="${2:-}"
  need_docker
  [ -f "$DIST_DIR/kkfileview-${ver}.tar.gz" ] || { log "dist 缺少 kkfileview-${ver}.tar.gz，先执行编译与打包"; do_build "$ver"; do_package; }

  local args=(build -f Dockerfile.runtime --build-arg "KK_VERSION=$ver" \
              -t "${RUNTIME_IMAGE}:${ver}" -t "${RUNTIME_IMAGE}:latest")
  [ -n "$platform" ] && args+=(--platform "$platform")

  log "构建运行时镜像: ${RUNTIME_IMAGE}:${ver}${platform:+（platform=${platform}）}"
  docker "${args[@]}" "$SCRIPT_DIR"
  log "镜像构建完成:"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E "^${RUNTIME_IMAGE}" || true
}

do_smoke() {
  local tag="${1:-${RUNTIME_IMAGE}:latest}"
  need_docker
  bash "$SCRIPT_DIR/smoke-test.sh" "$tag"
}

do_push() {
  [ $# -ge 1 ] || die "用法: ./build.sh push <镜像tag> [更多tag...]"
  need_docker
  local tag
  for tag in "$@"; do
    log "推送 ${tag}"
    docker push "$tag"
  done
}

do_native() {
  local ver="${1:-$DEFAULT_VERSION}" mirror="${2:-${MAVEN_MIRROR:-aliyun}}"
  log "宿主机原生编译（需要 JDK 8 + Maven 3.9+）"
  bash "$SCRIPT_DIR/build-kkfileview.sh" \
    --version "$ver" \
    --maven-mirror "$mirror" \
    --repo-url "${KK_REPO_URLS:-$DEFAULT_REPO_URLS}" \
    --output "$DIST_DIR"
  do_package
}

do_shell() {
  need_docker
  build_builder_image
  log "进入编译镜像交互式 shell（源码建议挂载到 /opt/src）"
  # 必须显式给出命令，否则 Docker 会沿用镜像的 CMD（--help），
  # 变成执行「/bin/bash --help」然后立刻退出
  docker run --rm -it \
    -v "$HOME/.m2:/root/.m2" \
    -v "$DIST_DIR:/opt/dist" \
    --entrypoint /bin/bash \
    "$BUILDER_IMAGE" -i
}

case "${1:-}" in
  build)   shift; do_build "$@" ;;
  package) shift; do_package ;;
  image)   shift; do_image "$@" ;;
  all)     shift; do_build "${1:-$DEFAULT_VERSION}"; do_package; do_image "${1:-$DEFAULT_VERSION}" ;;
  smoke)   shift; do_smoke "$@" ;;
  push)    shift; do_push "$@" ;;
  native)  shift; do_native "$@" ;;
  shell)   shift; do_shell ;;
  -h|--help|help|"") usage ;;
  *) die "未知命令: $1（用 --help 查看用法）" ;;
esac
