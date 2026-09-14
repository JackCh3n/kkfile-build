#!/usr/bin/env bash
# =============================================================================
# install.sh —— kkFileView 离线安装 / 原地升级脚本（发行包自包含，无需联网）
#
# 典型用法：
#   tar -xzf kkfileview-4.4.0.tar.gz
#   cd kkFileView-4.4.0
#   sudo ./install.sh --start
#
# 也可以直接从 tar.gz 安装：
#   sudo ./install.sh --from /path/to/kkfileview-4.4.0.tar.gz --start
#
# 脚本会做这些事：
#   1) 检查 Java（4.x 必须 8+，源码 maven.compiler.source/target=1.8）与 LibreOffice
#   2) 创建运行用户、安装目录、数据目录
#   3) 同步 bin/ config/ 到安装目录（升级时保留并备份旧配置、清理旧 jar）
#   4) 写 /etc/kkfileview/kkfileview.env 与 systemd 服务（可选）
#
# 前置依赖（脚本不会替你联网安装）：JDK 8+、LibreOffice。
#   Debian/Ubuntu : apt-get install -y openjdk-8-jre libreoffice-nogui fonts-wqy-microhei fonts-wqy-zenhei
#   RHEL/CentOS   : 可用发行包内的 bin/install.sh 下载 LibreOffice（需联网）
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 默认参数 ----------
PREFIX="/opt/kkfileview"
DATA_DIR="/var/lib/kkfileview"
RUN_USER="kkfileview"
PORT="8012"
ENV_DIR="/etc/kkfileview"
ENV_FILE="${ENV_DIR}/kkfileview.env"
UNIT_DIR="/etc/systemd/system"
UNIT_NAME="kkfileview.service"

WITH_SERVICE="yes"
START_AFTER="no"
INSTALL_OFFICE="no"
FORCE="no"
CHECK_ONLY="no"
DO_UNINSTALL="no"
PURGE="no"
KEEP_CONFIG="yes"
JAVA_HOME_ARG=""
PKG_DIR_ARG=""
FROM_TARBALL=""
# 运行所需最小 Java 版本：4.x 线产物是 Java 8 字节码（main 分支的 5.x 是 21）
MIN_JAVA_MAJOR="${MIN_JAVA_MAJOR:-8}"

# ---------- 运行期状态 ----------
PKG_DIR=""
PKG_VERSION=""
PKG_LABEL=""
JAVA_BIN=""
OFFICE_HOME=""
TMP_EXTRACT=""
RUN_GROUP=""

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$TMP_EXTRACT" ] && rm -rf "$TMP_EXTRACT"; return 0; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
kkFileView 离线安装 / 升级

用法: sudo ./install.sh [选项]

安装位置与身份:
  -p, --prefix DIR     安装目录             (默认 /opt/kkfileview)
      --data-dir DIR   运行数据目录         (默认 /var/lib/kkfileview)
      --user NAME      运行用户             (默认 kkfileview)
      --port N         服务端口             (默认 8012)
      --java-home DIR  指定 JAVA_HOME（须为 JDK/JRE 8+）
      --min-java N     运行所需最小 Java 版本（默认 8）

来源与行为:
      --pkg DIR        指定解包后的发行目录（默认取脚本所在目录）
      --from FILE      直接从 tar.gz 安装（自动解包到临时目录）
      --install-office 未检测到 LibreOffice 时调用包内 bin/install.sh 自动安装（需联网）
      --no-service     不创建 systemd 服务
      --start          安装完成后立即启动服务
      --no-keep-config 升级时不保留旧配置（默认保留并备份）
      --force          允许覆盖已存在的安装目录
      --check          只做环境自检并打印结论，不改动系统
      --uninstall      卸载（默认保留数据目录与配置）
      --purge          与 --uninstall 连用：连数据目录、配置一起删除
  -h, --help           显示本帮助
EOF
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--prefix)     PREFIX="${2:?--prefix 需要参数}"; shift 2 ;;
    --data-dir)      DATA_DIR="${2:?--data-dir 需要参数}"; shift 2 ;;
    --user)          RUN_USER="${2:?--user 需要参数}"; shift 2 ;;
    --port)          PORT="${2:?--port 需要参数}"; shift 2 ;;
    --java-home)     JAVA_HOME_ARG="${2:?--java-home 需要参数}"; shift 2 ;;
    --min-java)      MIN_JAVA_MAJOR="${2:?--min-java 需要参数}"; shift 2 ;;
    --pkg)           PKG_DIR_ARG="${2:?--pkg 需要参数}"; shift 2 ;;
    --from)          FROM_TARBALL="${2:?--from 需要参数}"; shift 2 ;;
    --install-office) INSTALL_OFFICE="yes"; shift ;;
    --no-service)    WITH_SERVICE="no"; shift ;;
    --start)         START_AFTER="yes"; shift ;;
    --no-keep-config) KEEP_CONFIG="no"; shift ;;
    --force)         FORCE="yes"; shift ;;
    --check)         CHECK_ONLY="yes"; shift ;;
    --uninstall)     DO_UNINSTALL="yes"; shift ;;
    --purge)         PURGE="yes"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

require_root() {
  [ "$(id -u)" = "0" ] || die "需要 root 权限，请用 sudo 执行"
}

# ---------- 发行目录定位 ----------
resolve_pkg_dir() {
  if [ -n "$FROM_TARBALL" ]; then
    [ -f "$FROM_TARBALL" ] || die "找不到文件: $FROM_TARBALL"
    TMP_EXTRACT="$(mktemp -d /tmp/kkfileview-install.XXXXXX)"
    log "解包: $FROM_TARBALL"
    tar -xzf "$FROM_TARBALL" -C "$TMP_EXTRACT"
    local cfg
    cfg="$(find "$TMP_EXTRACT" -maxdepth 3 -type f -name application.properties -path '*/config/*' -print -quit 2>/dev/null || true)"
    [ -n "$cfg" ] || die "压缩包结构异常：未找到 config/application.properties"
    PKG_DIR="$(dirname "$(dirname "$cfg")")"
  elif [ -n "$PKG_DIR_ARG" ]; then
    PKG_DIR="$(cd "$PKG_DIR_ARG" && pwd)"
  else
    PKG_DIR="$SCRIPT_DIR"
  fi

  [ -f "$PKG_DIR/config/application.properties" ] || die "$PKG_DIR 不是有效的发行目录（缺少 config/application.properties）"
  [ -n "$(ls -1 "$PKG_DIR"/bin/kkFileView-*.jar 2>/dev/null || true)" ] || die "$PKG_DIR/bin 下缺少 kkFileView-*.jar"

  PKG_VERSION="$(basename "$PKG_DIR")"
  PKG_VERSION="${PKG_VERSION#kkFileView-}"
  if [ -f "$PKG_DIR/BUILD-INFO.txt" ]; then
    # grep -m1 自己就会在读满一条后退出，不会给上游造成 SIGPIPE
    local v
    v="$(grep -m1 -E '^项目版本' "$PKG_DIR/BUILD-INFO.txt" 2>/dev/null | sed -E 's/^[^:]*:[[:space:]]*//' || true)"
    [ -n "$v" ] && PKG_VERSION="$v"
  fi
  PKG_LABEL="kkFileView ${PKG_VERSION}"
  log "发行目录: $PKG_DIR（${PKG_LABEL}）"
}

# ---------- Java 检测 ----------
java_major_version() {
  local all first major
  # 先全量捕获再取首行（原因同 build-kkfileview.sh：避免 head 造成的 SIGPIPE）
  all="$("$1" -version 2>&1 || true)"
  first="${all%%$'\n'*}"
  major="$(printf '%s' "$first" | sed -nE 's/.*version "([0-9]+).*/\1/p')"
  if [ "$major" = "1" ]; then
    printf '%s' "$first" | sed -nE 's/.*version "1\.([0-9]+).*/\1/p'
  else
    printf '%s' "$major"
  fi
}

find_java() {
  local cand="" d
  if [ -n "$JAVA_HOME_ARG" ]; then
    cand="$JAVA_HOME_ARG/bin/java"
    [ -x "$cand" ] || die "--java-home 下没有 bin/java: $JAVA_HOME_ARG"
    printf '%s' "$cand"; return 0
  fi
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    printf '%s' "$JAVA_HOME/bin/java"; return 0
  fi
  if command -v java >/dev/null 2>&1; then
    command -v java; return 0
  fi
  for d in /usr/lib/jvm/*/bin/java /usr/java/*/bin/java /opt/*/bin/java /usr/local/*/bin/java; do
    if [ -x "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

check_java() {
  log "检查 Java..."
  if ! JAVA_BIN="$(find_java)"; then
    die "未找到 java。请安装 JDK 8+（apt-get install -y openjdk-8-jre），或用 --java-home 指定"
  fi
  local major
  major="$(java_major_version "$JAVA_BIN")"
  case "$major" in
    ''|*[!0-9]*) die "无法识别 Java 版本：$("$JAVA_BIN" -version 2>&1 | head -n1)" ;;
  esac
  [ "$major" -ge "$MIN_JAVA_MAJOR" ] || die "需要 Java ${MIN_JAVA_MAJOR} 或更高版本（当前 $major）：$JAVA_BIN"
  log "Java: $("$JAVA_BIN" -version 2>&1 | head -n1) [$JAVA_BIN]"
}

# ---------- LibreOffice 检测 ----------
# 与 kkFileView 的 LocalOfficeUtils 搜索路径保持一致：<home>/program/soffice.bin
# 纯查找函数：找到返回 0 并设置 OFFICE_HOME，找不到返回 1（不做任何安装动作，
# 因此可以安全地被 ensure_office / do_check 反复调用）
office_scan() {
  local p
  for p in \
    /opt/libreoffice6.0 /opt/libreoffice6.1 /opt/libreoffice6.2 /opt/libreoffice6.3 /opt/libreoffice6.4 \
    /opt/libreoffice7.0 /opt/libreoffice7.1 /opt/libreoffice7.2 /opt/libreoffice7.3 /opt/libreoffice7.4 \
    /opt/libreoffice7.5 /opt/libreoffice7.6 /opt/libreoffice24.2 /opt/libreoffice24.8 \
    /opt/libreoffice25.2 /opt/libreoffice25.8 /opt/libreoffice26.2 /opt/libreoffice26.8 \
    /opt/libreoffice \
    /usr/lib64/libreoffice /usr/lib/libreoffice /usr/local/lib64/libreoffice /usr/local/lib/libreoffice \
    /usr/lib64/openoffice /usr/lib/openoffice /opt/openoffice4
  do
    if [ -f "$p/program/soffice.bin" ]; then
      OFFICE_HOME="$p"
      return 0
    fi
  done
  OFFICE_HOME=""
  return 1
}

# 安装流程用：缺失时可选联网安装，仍缺失则明确失败
ensure_office() {
  log "检查 LibreOffice..."
  if office_scan; then
    log "LibreOffice: $OFFICE_HOME"
    return 0
  fi

  warn "未检测到 LibreOffice —— kkFileView 启动时会强制要求 office.home，服务将无法启动！"
  if [ "$INSTALL_OFFICE" = "yes" ]; then
    local inst="$PKG_DIR/bin/install.sh"
    [ -f "$inst" ] || die "包内缺少 bin/install.sh，无法自动安装 LibreOffice"
    log "尝试自动安装 LibreOffice（需要联网，可能耗时较久）..."
    ( cd "$(dirname "$inst")" && sh ./install.sh ) || warn "LibreOffice 安装脚本返回非零，继续检查是否已可用"
    if office_scan; then
      log "LibreOffice: $OFFICE_HOME"
      return 0
    fi
    die "自动安装后仍未检测到 LibreOffice，请手工安装（apt-get install -y libreoffice-nogui）"
  fi

  warn "请手工安装 LibreOffice（apt-get install -y libreoffice-nogui），或加 --install-office 由脚本联网安装"
  return 1
}

# ---------- 环境自检 ----------
do_check() {
  local rc=0
  check_java
  ensure_office || rc=1
  printf '\n'
  log "自检结论"
  printf '  发行版本      : %s\n' "$PKG_LABEL"
  printf '  发行目录      : %s\n' "$PKG_DIR"
  printf '  Java          : %s\n' "$JAVA_BIN"
  printf '  LibreOffice   : %s\n' "${OFFICE_HOME:-未检测到（服务将无法启动）}"
  printf '  拟安装目录    : %s\n' "$PREFIX"
  printf '  拟数据目录    : %s\n' "$DATA_DIR"
  printf '  运行用户      : %s\n' "$RUN_USER"
  printf '  服务端口      : %s\n' "$PORT"
  if [ "$rc" != "0" ]; then
    warn "自检未通过：缺少运行必需组件（见上）"
  fi
  return "$rc"
}

# ---------- 运行用户 ----------
ensure_user() {
  if id "$RUN_USER" >/dev/null 2>&1; then
    log "运行用户已存在: $RUN_USER"
    return 0
  fi
  log "创建运行用户: $RUN_USER"
  # 家目录指向安装目录，保证 LibreOffice 有可写的 HOME
  useradd -r -M -d "$PREFIX" -s /usr/sbin/nologin "$RUN_USER" 2>/dev/null \
    || useradd -r -M -d "$PREFIX" -s /sbin/nologin "$RUN_USER" \
    || useradd -r -M -d "$PREFIX" "$RUN_USER"
  RUN_GROUP="$(id -gn "$RUN_USER")"
}

# ---------- 安装文件 ----------
install_files() {
  local bak=""
  mkdir -p "$PREFIX" "$PREFIX/bin" "$PREFIX/config" "$PREFIX/log" "$DATA_DIR/file" "$DATA_DIR/preview"

  # 升级时保留旧配置
  if [ -f "$PREFIX/config/application.properties" ] && [ "$KEEP_CONFIG" = "yes" ]; then
    bak="$PREFIX/config/application.properties.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$PREFIX/config/application.properties" "$bak"
    log "已备份旧配置: $bak"
  fi

  # 清理上一版本的 jar，避免多版本 jar 同时存在导致启动脚本取错
  rm -f "$PREFIX"/bin/kkFileView-*.jar 2>/dev/null || true

  log "同步程序文件到 $PREFIX"
  cp -a "$PKG_DIR/bin/." "$PREFIX/bin/"
  cp -a "$PKG_DIR/config/." "$PREFIX/config/"
  [ -d "$PKG_DIR/log" ] && cp -a "$PKG_DIR/log/." "$PREFIX/log/" 2>/dev/null || true

  # 附带文件（便于运维就地查看）
  local f
  for f in install.sh kkfileview.service kkfileview.env.example LICENSE LICENSE.kkfileview.txt BUILD-INFO.txt README.md; do
    [ -f "$PKG_DIR/$f" ] && cp -f "$PKG_DIR/$f" "$PREFIX/$f"
  done

  if [ -n "$bak" ]; then
    cp -f "$bak" "$PREFIX/config/application.properties"
    log "已恢复旧配置（新版本配置见 ${PREFIX}/config，如需用新配置请手动替换）"
  fi

  chmod 0755 "$PREFIX"/bin/*.sh 2>/dev/null || true
  chmod 0755 "$PREFIX/install.sh" 2>/dev/null || true
  chown -R "$RUN_USER":"$RUN_GROUP" "$PREFIX" "$DATA_DIR"
  log "文件同步完成"
}

# ---------- 环境变量文件 ----------
write_env_file() {
  mkdir -p "$ENV_DIR"
  if [ -f "$ENV_FILE" ]; then
    log "环境变量文件已存在，保持不动: $ENV_FILE"
    return 0
  fi
  log "写入环境变量文件: $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# kkFileView 环境变量（由 install.sh 生成，修改后 systemctl restart kkfileview 生效）
JAVA_OPTS=-Xms512m -Xmx2g -Dfile.encoding=UTF-8
KK_SERVER_PORT=${PORT}
KK_CONTEXT_PATH=/
KK_OFFICE_HOME=${OFFICE_HOME:-default}
KK_FILE_DIR=${DATA_DIR}/file
KK_LOCAL_PREVIEW_DIR=${DATA_DIR}/preview
EOF
  chmod 0644 "$ENV_FILE"
}

# ---------- systemd ----------
install_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "系统没有 systemctl，跳过服务安装；可用 $PREFIX/bin/kkfileview-run.sh 手工启动"
    return 0
  fi
  local src="$PKG_DIR/kkfileview.service"
  [ -f "$src" ] || src="$PREFIX/kkfileview.service"
  [ -f "$src" ] || die "缺少 systemd 服务模板 kkfileview.service"

  [ "$RUN_USER" = "root" ] && RUN_GROUP="root"
  log "安装 systemd 服务: ${UNIT_DIR}/${UNIT_NAME}"
  sed -e "s@__PREFIX__@${PREFIX}@g" \
      -e "s@__RUN_USER__@${RUN_USER}@g" \
      -e "s@__RUN_GROUP__@${RUN_GROUP}@g" \
      -e "s@__ENV_FILE__@${ENV_FILE}@g" \
      "$src" > "${UNIT_DIR}/${UNIT_NAME}"
  chmod 0644 "${UNIT_DIR}/${UNIT_NAME}"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || warn "systemctl enable 失败，请手工 enable"
  log "服务已安装（未自动启动，使用 systemctl start ${UNIT_NAME}）"
}

# ---------- 卸载 ----------
do_uninstall() {
  log "卸载 kkFileView"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "${UNIT_DIR}/${UNIT_NAME}"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true

  if [ "$PREFIX" != "/" ] && [ -d "$PREFIX" ]; then
    log "删除安装目录: $PREFIX"
    rm -rf "$PREFIX"
  fi
  rm -f "$ENV_FILE"

  if [ "$PURGE" = "yes" ]; then
    if [ "$DATA_DIR" != "/" ] && [ -d "$DATA_DIR" ]; then
      log "删除数据目录: $DATA_DIR"
      rm -rf "$DATA_DIR"
    fi
    rmdir "$ENV_DIR" 2>/dev/null || true
    log "数据与配置已清除"
  else
    log "已保留数据目录: $DATA_DIR（如需一并删除请加 --purge）"
  fi

  if id "$RUN_USER" >/dev/null 2>&1; then
    log "运行用户 $RUN_USER 保留（如需删除：userdel $RUN_USER）"
  fi
  log "卸载完成"
}

# ---------- 汇总 ----------
print_summary() {
  local ctx="/"
  grep -qE '^[[:space:]]*KK_CONTEXT_PATH[[:space:]]*=' "$ENV_FILE" 2>/dev/null \
    && ctx="$(sed -nE 's/^[[:space:]]*KK_CONTEXT_PATH[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -n1)"
  printf '\n'
  log "安装完成 —— ${PKG_LABEL}"
  printf '  安装目录   : %s\n' "$PREFIX"
  printf '  配置文件   : %s/config/application.properties\n' "$PREFIX"
  printf '  环境变量   : %s\n' "$ENV_FILE"
  printf '  数据目录   : %s\n' "$DATA_DIR"
  printf '  访问地址   : http://<服务器IP>:%s%s\n' "$PORT" "$ctx"
  printf '  健康检查   : http://127.0.0.1:%s%s（首页，HTTP 2xx 即就绪）\n' "$PORT" "$ctx"
  printf '  启动服务   : systemctl start %s\n' "$UNIT_NAME"
  printf '  查看日志   : journalctl -u %s -f\n' "$UNIT_NAME"
  printf '  手工启动   : %s/bin/kkfileview-run.sh\n' "$PREFIX"
  printf '\n'
}

# ---------- 主流程 ----------
main() {
  log "install.sh v${SCRIPT_VERSION}"

  # --uninstall / --check 之前先解析发行包，便于给出有意义的报错
  if [ "$DO_UNINSTALL" = "yes" ]; then
    require_root
    do_uninstall
    exit 0
  fi

  resolve_pkg_dir

  # 自检模式不改动系统，因此不要求 root
  if [ "$CHECK_ONLY" = "yes" ]; then
    do_check || exit 1
    exit 0
  fi

  require_root
  check_java
  ensure_office || true

  # 安装目录非空时的三种情况：已有 kkFileView（走升级）/ 明确 --force 覆盖 /
  # 既非 kkFileView 又没加 --force（拒绝，避免 --prefix 指错目录把别人的数据覆盖掉）
  if [ -d "$PREFIX" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null || true)" ]; then
    if [ -f "$PREFIX/config/application.properties" ] \
       || [ -n "$(ls -1 "$PREFIX"/bin/kkFileView-*.jar 2>/dev/null || true)" ]; then
      log "检测到已有 kkFileView 安装（$PREFIX），按升级方式处理（旧配置会备份保留）"
    elif [ "$FORCE" = "yes" ]; then
      warn "$PREFIX 非空且不像 kkFileView 安装目录，已按 --force 覆盖"
    else
      die "$PREFIX 非空，且不像 kkFileView 安装目录
    （既没有 bin/kkFileView-*.jar，也没有 config/application.properties）。
    确认要安装到这里请加 --force，或用 --prefix 指定其它目录。"
    fi
  fi

  ensure_user
  RUN_GROUP="${RUN_GROUP:-$(id -gn "$RUN_USER")}"
  install_files
  write_env_file
  [ "$WITH_SERVICE" = "yes" ] && install_service || true

  if [ "$START_AFTER" = "yes" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ "$WITH_SERVICE" = "yes" ]; then
      log "启动服务: ${UNIT_NAME}"
      systemctl restart "$UNIT_NAME"
      sleep 3
      systemctl --no-pager --lines=0 status "$UNIT_NAME" || true
    else
      warn "无法启动服务（缺少 systemctl 或指定了 --no-service）"
    fi
  fi

  print_summary

  if [ -z "$OFFICE_HOME" ]; then
    warn "提醒：未检测到 LibreOffice，服务启动会失败，请先安装："
    warn "      Debian/Ubuntu: apt-get install -y libreoffice-nogui fonts-wqy-microhei fonts-wqy-zenhei"
  fi
}

main "$@"
