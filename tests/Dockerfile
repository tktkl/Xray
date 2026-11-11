ARG BASE=ubuntu:24.04
FROM ${BASE}
ARG APT_MIRROR
USER root
ENTRYPOINT []
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN if [ -n "$APT_MIRROR" ]; then if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then sed -i "s|http://ports.ubuntu.com/ubuntu-ports|$APT_MIRROR|g" /etc/apt/sources.list.d/ubuntu.sources; else sed -i "s|http://deb.debian.org|$APT_MIRROR|g" /etc/apt/sources.list.d/debian.sources; fi; fi
RUN apt-get update && apt-get install -y --no-install-recommends bash jq curl ca-certificates openssl unzip nginx certbot python3-certbot-dns-cloudflare systemd systemd-sysv dbus iproute2 procps util-linux netcat-openbsd python3 shellcheck bats dnsutils qrencode && rm -rf /var/lib/apt/lists/*
RUN useradd --system --no-create-home --shell /usr/sbin/nologin xray-manager && mkdir -p /opt/xray-core /run/xray-manager && chown xray-manager:xray-manager /run/xray-manager
WORKDIR /src
CMD ["bash", "tests/run.sh"]
