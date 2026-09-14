#!/usr/bin/env bash
# =============================================================================
# package-dist.sh —— 把编译产物打成一个「自包含、可离线一键安装」的发行包
#
# 输入：build-kkfileview.sh 产出的 dist/kkFileView-<版本>/（解包后的发行目录）
# 输出：
#   dist/kkfileview-<版本>.tar.gz    最终发布包（含 install.sh / systemd 服务 / 许可证）
#   dist/kkFileView-<版本>.jar       原始 fat jar（单独发布，便于只想要 jar 的用户）
#   dist/SHA256SUMS                  校验和
#
# 之所以独立于 build-kkfileview.sh：编译在 builder 镜像里跑，镜像里只有
# build-kkfileview.sh 一个文件；而这里要往包里塞仓库中的 install.sh 与 assets/，
# 所以由宿主机 / CI 在编译之后执行。
#
# 用法：package-dist.sh [--dist DIR] [--pkg DIR] [--version VER]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
PKG_DIR=""
VERSION=""

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: package-dist.sh [选项]
  --dist DIR      产物目录（默认 <脚本目录>/dist）
  --pkg DIR       指定要打包的发行目录（默认取 dist/ 下最新的 kkFileView-*）
  --version VER   指定版本号（默认从发行目录名推断）
  -h, --help      显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dist)    DIST_DIR="${2:?--dist 需要参数}"; shift 2 ;;
    --pkg)     PKG_DIR="${2:?--pkg 需要参数}"; shift 2 ;;
    --version) VERSION="${2:?--version 需要参数}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -d "$DIST_DIR" ] || die "产物目录不存在: $DIST_DIR"

# ---------- 定位发行目录 ----------
# 注意：这里用 awk 取第一行而不是 `head -n1`。head 命中即退出会给上游命令发
# SIGPIPE，在 set -o pipefail 下会让整个管道返回非 0，进而因 set -e 中止脚本。
if [ -z "$PKG_DIR" ]; then
  PKG_DIR="$( { find "$DIST_DIR" -maxdepth 1 -type d -name 'kkFileView-*' -printf '%T@ %p\n' 2>/dev/null || true; } \
             | sort -rn | awk 'NR==1{print $2}' )"
  # find -printf 是 GNU 专有；macOS 回退到 ls -dt
  if [ -z "$PKG_DIR" ]; then
    PKG_DIR="$(ls -dt "$DIST_DIR"/kkFileView-*/ 2>/dev/null | sed -n '1p' || true)"
    PKG_DIR="${PKG_DIR%/}"
  fi
fi
[ -n "$PKG_DIR" ] && [ -d "$PKG_DIR" ] || die "未找到发行目录（$DIST_DIR/kkFileView-*），请先执行 build.sh build"
log "发行目录: $PKG_DIR"

[ -f "$PKG_DIR/config/application.properties" ] || die "$PKG_DIR 不是有效的发行目录（缺少 config/application.properties）"
[ -n "$(ls -1 "$PKG_DIR"/bin/kkFileView-*.jar 2>/dev/null || true)" ] || die "$PKG_DIR/bin 下缺少 kkFileView-*.jar"

# ---------- 版本号 ----------
if [ -z "$VERSION" ]; then
  VERSION="$(basename "$PKG_DIR")"
  VERSION="${VERSION#kkFileView-}"
fi
[ -n "$VERSION" ] || die "无法推断版本号，请用 --version 指定"
log "版本号: $VERSION"

# ---------- 注入自包含文件 ----------
copy_file() { # <源> <目标> <权限>
  local src="$1" dst="$2" mode="$3"
  [ -f "$src" ] || { warn "缺少文件，跳过: $src"; return 0; }
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  chmod "$mode" "$dst"
  log "注入 $(basename "$dst")"
}

copy_file "${SCRIPT_DIR}/install.sh"                     "${PKG_DIR}/install.sh"                 0755
copy_file "${SCRIPT_DIR}/assets/kkfileview-run.sh"       "${PKG_DIR}/bin/kkfileview-run.sh"      0755
copy_file "${SCRIPT_DIR}/assets/kkfileview.service"      "${PKG_DIR}/kkfileview.service"         0644
copy_file "${SCRIPT_DIR}/assets/kkfileview.env.example"  "${PKG_DIR}/kkfileview.env.example"     0644
copy_file "${SCRIPT_DIR}/LICENSE"                        "${PKG_DIR}/LICENSE"                    0644
copy_file "${SCRIPT_DIR}/README.md"                      "${PKG_DIR}/README.md"                  0644
# 上游许可证：由 build-kkfileview.sh 从源码目录复制出来，放在产物目录根部
copy_file "${DIST_DIR}/LICENSE.kkfileview.txt"           "${PKG_DIR}/LICENSE.kkfileview.txt"     0644
# 构建信息：BUILD-INFO.txt 在产物目录根部，拷进包里便于离线追溯
copy_file "${DIST_DIR}/BUILD-INFO.txt"                   "${PKG_DIR}/BUILD-INFO.txt"             0644

# 保证 bin/ 下脚本可执行（解包/复制过程可能丢掉执行位）
chmod 0755 "$PKG_DIR"/bin/*.sh 2>/dev/null || true

# ---------- 打包 ----------
# 说明：编译产物由容器内 root 创建，个别文件权限可能是 0600，非 root 打包会
#       Permission denied；统一放开读权限（a+rX 不会给普通文件加执行位）。
chmod -R a+rX "$PKG_DIR" 2>/dev/null || true

TARBALL="${DIST_DIR}/kkfileview-${VERSION}.tar.gz"
rm -f "$TARBALL"

TAR_OPTS=()
TAR_VERSION_OUT="$(tar --version 2>/dev/null || true)"
case "$TAR_VERSION_OUT" in
  # 用 case 而不是 `tar --version | grep -q`：grep -q 命中即退出会给 tar 发
  # SIGPIPE，在 set -o pipefail 下会把 GNU tar 误判成非 GNU tar
  *"GNU tar"*) TAR_OPTS+=(--sort=name --owner=0 --group=0 --numeric-owner) ;;
esac

log "打包: $(basename "$TARBALL")"
# 说明：bsdtar(macOS) 下 TAR_OPTS 为空数组，而老版本 bash 在 set -u 下展开
# 空数组会报 unbound variable，所以这里分两种情况显式写
if [ "${#TAR_OPTS[@]}" -gt 0 ]; then
  ( cd "$DIST_DIR" && tar "${TAR_OPTS[@]}" -czf "$(basename "$TARBALL")" "$(basename "$PKG_DIR")" )
else
  ( cd "$DIST_DIR" && tar -czf "$(basename "$TARBALL")" "$(basename "$PKG_DIR")" )
fi
[ -s "$TARBALL" ] || die "打包失败: $TARBALL"

# ---------- 校验和 ----------
# 注意：必须在「子 shell」里 cd。之前写成 `{ ...; } > "$SHA_FILE"`，
# cd 会改变脚本自身的工作目录——当 --dist 传的是相对路径（CI 就是 `--dist dist`）时，
# 后续所有相对路径都会变成 dist/dist/...，导致脚本末尾误报失败。
SHA_FILE="${DIST_DIR}/SHA256SUMS"
(
  cd "$DIST_DIR" || exit 1
  T="$(basename "$TARBALL")"
  J="kkFileView-${VERSION}.jar"
  if [ -f "$T" ] && [ -f "$J" ]; then
    sha256sum "$T" "$J"
  elif [ -f "$T" ]; then
    sha256sum "$T"
  fi
) > "$SHA_FILE" || warn "生成 SHA256SUMS 失败"

# 结尾不用 `[ ... ] && ...` 形式：作为最后一条命令，条件不成立会让脚本以非 0 退出
log "打包完成:"
ls -lh "$TARBALL" 2>/dev/null || true
ls -lh "$DIST_DIR/kkFileView-${VERSION}.jar" 2>/dev/null || true
if [ -s "$SHA_FILE" ]; then
  log "校验和:"
  cat "$SHA_FILE"
else
  warn "SHA256SUMS 为空或缺失"
fi
exit 0
