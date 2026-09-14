# syntax=docker/dockerfile:1
# =============================================================================
# kkfile-build · 编译镜像（builder）
#
# 作用：提供一个「Maven 3.9 + Temurin JDK 21 + git」的 Linux 环境，用于从源码
#       编译 kkFileView（Spring Boot 3.5 / Java 21），产出自包含发行目录。
#
# 用法：
#   docker build -t kkfileview-builder:local -f Dockerfile .
#   docker run --rm -v "$PWD/dist:/opt/dist" -v "$HOME/.m2:/root/.m2" \
#     kkfileview-builder:local --version 5.0.2 --output /opt/dist
#
# 关键设计
# ---------
# 1) 基础镜像默认 maven:3.9-eclipse-temurin-21（Ubuntu 24.04 + Temurin JDK 21），
#    可用 --build-arg BUILDER_IMAGE=<image> 覆盖（便于固定到具体小版本）。
# 2) Maven 镜像源不在构建期固化：build-kkfileview.sh 在「运行期」生成 settings.xml，
#    通过 --maven-mirror aliyun|central|huawei|tencent|none|<url> 切换，换源无需重建镜像。
# 3) 本镜像故意不安装 LibreOffice。kkFileView 的 OfficePluginManager 是
#    @PostConstruct，找不到 office.home 会直接抛异常导致进程退出；因此冒烟测试
#    （起进程 + 探活 /actuator/health）必须放在装了 LibreOffice 的运行时镜像里做，
#    见 Dockerfile.runtime 与 smoke-test.sh。
# =============================================================================

ARG BUILDER_IMAGE=maven:3.9-eclipse-temurin-21
FROM ${BUILDER_IMAGE}

# APT 镜像（Ubuntu/Debian 两种 sources 格式都做了兼容），留空表示用基础镜像默认源。
# 用 http 即可：deb 包有 GPG 签名，http 传输不影响完整性（https 还要求镜像里
# 预置 ca-certificates，裸基础镜像没有）。这里不改变 Maven 依赖下载源。
ARG APT_MIRROR=http://mirrors.aliyun.com

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
      if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i -E "s@https?://(archive|security|ports)\.ubuntu\.com@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
      fi; \
      if [ -f /etc/apt/sources.list ]; then \
        sed -i -E "s@https?://(deb|archive|security|ports)\.debian\.org@${APT_MIRROR}@g" /etc/apt/sources.list; \
      fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git curl ca-certificates unzip xz-utils tzdata; \
    rm -rf /var/lib/apt/lists/*

# kkFileView 的 JavaCV / opencv / ffmpeg 依赖包体较大，给 Maven 多一点堆
ENV MAVEN_OPTS="-Xmx2g"

COPY build-kkfileview.sh /usr/local/bin/build-kkfileview.sh
RUN chmod 0755 /usr/local/bin/build-kkfileview.sh

WORKDIR /opt/src
ENTRYPOINT ["/usr/local/bin/build-kkfileview.sh"]
CMD ["--help"]
