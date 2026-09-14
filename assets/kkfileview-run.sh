#!/bin/sh
# =============================================================================
# kkfileview-run.sh —— kkFileView 前台启动脚本
#
# 同一个脚本被两处复用，保证容器与裸机的启动参数完全一致：
#   * Docker 镜像 ENTRYPOINT（/usr/local/bin/kkfileview -> 本脚本）
#   * systemd 服务 ExecStart（<安装目录>/bin/kkfileview-run.sh）
#
# 设计要点：
#   1) 目录不写死：默认取脚本自身所在目录作为 KKFILEVIEW_BIN_FOLDER，
#      因此换安装前缀（/opt/kkfileview、/usr/local/kkfileview…）都不用改脚本；
#   2) 前台运行、exec 交替换进程，便于 systemd / docker 正确管理生命周期与信号；
#   3) kkFileView 通过 KKFILEVIEW_BIN_FOLDER 反推 home 目录（去掉结尾的 bin），
#      进而定位 config/application.properties 与 file/ 目录，所以这个变量必须导出。
# =============================================================================
set -eu

# 解析自身真实路径：容器里通过 /usr/local/bin/kkfileview 符号链接调用，
# 直接 dirname "$0" 会得到 /usr/local/bin 而不是真正的 bin 目录。
SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  resolved="$(readlink -f "$SELF" 2>/dev/null || true)"
  [ -n "$resolved" ] && SELF="$resolved"
fi
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
: "${KKFILEVIEW_BIN_FOLDER:=$SELF_DIR}"
export KKFILEVIEW_BIN_FOLDER
HOME_DIR="$(dirname "$KKFILEVIEW_BIN_FOLDER")"

# 定位可执行 jar（正常只有一个）
JAR=""
for f in "$KKFILEVIEW_BIN_FOLDER"/kkFileView-*.jar; do
  if [ -f "$f" ]; then
    JAR="$f"
    break
  fi
done
if [ -z "$JAR" ]; then
  echo "[kkfileview] 未在 $KKFILEVIEW_BIN_FOLDER 找到 kkFileView-*.jar" >&2
  exit 1
fi

# 配置文件：优先 KKFILEVIEW_CONFIG_FILE，其次 <home>/config/application.properties
CFG="${KKFILEVIEW_CONFIG_FILE:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
  CFG="$HOME_DIR/config/application.properties"
fi
if [ ! -f "$CFG" ]; then
  echo "[kkfileview] 配置文件不存在: $CFG" >&2
  exit 1
fi

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA_BIN="$JAVA_HOME/bin/java"
else
  JAVA_BIN="java"
fi

JAVA_OPTS="${JAVA_OPTS:--Xms512m -Xmx2g}"

echo "[kkfileview] bin    = $KKFILEVIEW_BIN_FOLDER"
echo "[kkfileview] jar    = $JAR"
echo "[kkfileview] config = $CFG"
echo "[kkfileview] java   = $JAVA_BIN"
echo "[kkfileview] opts   = $JAVA_OPTS"

# JAVA_OPTS 需要按空格拆成多个 JVM 参数，所以这里故意不加引号
# shellcheck disable=SC2086
exec "$JAVA_BIN" $JAVA_OPTS \
  -Dfile.encoding=UTF-8 \
  -Dspring.config.location="$CFG" \
  -jar "$JAR"
