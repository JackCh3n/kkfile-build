#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh —— 运行时镜像冒烟测试
#
# 为什么必须对「运行时镜像」做而编译阶段不能做：
#   kkFileView 的 OfficePluginManager 是 @PostConstruct，找不到 office.home 会抛异常
#   让进程直接退出。所以只要能起得来、/actuator/health 返回 UP，就顺带证明
#   镜像里的 LibreOffice 被正确识别（JDK/配置/权限/字体链路都是通的）。
#
# 用法：
#   ./smoke-test.sh <镜像> [--port N] [--timeout SEC] [--keep] [--no-office-check]
#
# 退出码：0 = 通过；非 0 = 失败（并输出容器日志尾部）
# =============================================================================
set -euo pipefail

IMAGE="${1:-}"
[ -n "$IMAGE" ] || { echo "用法: smoke-test.sh <镜像> [--port N] [--timeout SEC] [--keep]" >&2; exit 2; }
shift

HOST_PORT=""
TIMEOUT=300
KEEP="no"
OFFICE_CHECK="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --port)            HOST_PORT="${2:?--port 需要参数}"; shift 2 ;;
    --timeout)         TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    --keep)            KEEP="yes"; shift ;;
    --no-office-check) OFFICE_CHECK="no"; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '>>> %s\n' "$*"; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未找到 docker"

NAME="kkfileview-smoke-$$"
[ -n "$HOST_PORT" ] || HOST_PORT=$(( 20000 + (RANDOM % 20000) ))

cleanup() {
  if [ "$KEEP" = "yes" ]; then
    log "保留容器: $NAME（端口 $HOST_PORT）"
  else
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

dump_logs() {
  printf '\n----- docker logs（尾部 80 行）-----\n' >&2
  docker logs --tail 80 "$NAME" 2>&1 >&2 || true
  printf -- '------------------------------------\n\n' >&2
}

# ---------- 1) 镜像内的静态检查：LibreOffice 是否就位 ----------
if [ "$OFFICE_CHECK" = "yes" ]; then
  log "检查镜像内 LibreOffice 是否存在"
  # 注意：镜像 ENTRYPOINT 是应用启动脚本，这里必须用 --entrypoint 覆盖
  if docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -x /usr/lib/libreoffice/program/soffice.bin'; then
    log "LibreOffice: /usr/lib/libreoffice/program/soffice.bin 存在"
  else
    die "镜像内未找到 /usr/lib/libreoffice/program/soffice.bin —— kkFileView 将无法启动
    可执行下面命令人工确认：
      docker run --rm --entrypoint /bin/sh $IMAGE -c 'ls -la /usr/lib/libreoffice/program/ | head'"
  fi
fi

# ---------- 2) 起容器 ----------
log "启动容器: $NAME（host ${HOST_PORT} -> container 8012，镜像 $IMAGE）"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "${HOST_PORT}:8012" "$IMAGE" >/dev/null

# ---------- 3) 轮询健康检查 ----------
HEALTH_URL="http://127.0.0.1:${HOST_PORT}/actuator/health"
log "轮询 ${HEALTH_URL}（最长 ${TIMEOUT}s）"

deadline=$(( $(date +%s) + TIMEOUT ))
ok="no"
while [ "$(date +%s)" -lt "$deadline" ]; do
  running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
  if [ "$running" != "true" ]; then
    dump_logs
    die "容器已退出（启动失败）"
  fi
  body="$(curl -fsS -m 5 "$HEALTH_URL" 2>/dev/null || true)"
  case "$body" in
    *'"status":"UP"'*)
      log "健康检查通过: $body"
      ok="yes"
      break
      ;;
  esac
  sleep 5
done

if [ "$ok" != "yes" ]; then
  dump_logs
  die "等待 ${TIMEOUT}s 后 /actuator/health 仍未返回 UP"
fi

# ---------- 4) 首页可访问性 ----------
if curl -fsS -m 10 -o /dev/null "http://127.0.0.1:${HOST_PORT}/"; then
  log "首页可访问: http://127.0.0.1:${HOST_PORT}/"
else
  log "提示：首页 / 未返回 2xx（不影响服务可用性判断，可自行确认）"
fi

log "冒烟测试通过 ✔"
