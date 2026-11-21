# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
# (ALPINE_VERSION intentionally has no default, it comes from build.config.)

# Based on https://github.com/crazy-max/docker-matomo (MIT License).
# Differences from upstream:
#   - all versions and URLs come from build.config (no defaults here, the build
#     fails fast when an argument is missing),
#   - the Matomo tarball is verified against the official release signing key,
#   - packages from the Alpine base image are upgraded, so security fixes of
#     base packages (musl, busybox, libcrypto, ...) land on every rebuild,
#   - downloads fail on HTTP errors instead of silently storing error pages.

ARG ALPINE_VERSION

FROM tianon/gosu:latest AS gosu

FROM --platform=${BUILDPLATFORM} alpine:${ALPINE_VERSION} AS download
RUN apk --update --no-cache add curl gnupg tar unzip xz
ARG MATOMO_VERSION
ARG MATOMO_DOWNLOAD_BASE_URL
ARG MATOMO_GPG_FINGERPRINT
ARG UNIFONT_URL
ARG GEOIP_MMDB_BASE_URL
COPY keys/matomo-release-signing-key.asc /tmp/matomo-release-signing-key.asc
WORKDIR /dist/matomo
RUN set -eu; \
  for arg in MATOMO_VERSION MATOMO_DOWNLOAD_BASE_URL MATOMO_GPG_FINGERPRINT UNIFONT_URL GEOIP_MMDB_BASE_URL; do \
    eval "value=\${$arg:-}"; \
    if [ -z "$value" ]; then echo "ERROR: build argument $arg is required" >&2; exit 1; fi; \
  done; \
  export GNUPGHOME="$(mktemp -d)"; \
  gpg --batch --import /tmp/matomo-release-signing-key.asc; \
  if ! gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::${MATOMO_GPG_FINGERPRINT}:\$"; then \
    echo "ERROR: signing key fingerprint does not match MATOMO_GPG_FINGERPRINT" >&2; exit 1; \
  fi; \
  curl -fsSL -o /tmp/matomo.tar.gz "${MATOMO_DOWNLOAD_BASE_URL}/matomo-${MATOMO_VERSION}.tar.gz"; \
  curl -fsSL -o /tmp/matomo.tar.gz.asc "${MATOMO_DOWNLOAD_BASE_URL}/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
  gpg --batch --verify /tmp/matomo.tar.gz.asc /tmp/matomo.tar.gz; \
  tar xzf /tmp/matomo.tar.gz matomo --strip 1; \
  grep -q "const VERSION = '${MATOMO_VERSION}';" core/Version.php; \
  rm -rf "$GNUPGHOME" /tmp/matomo.tar.gz /tmp/matomo.tar.gz.asc /tmp/matomo-release-signing-key.asc
RUN curl -fsSL "${UNIFONT_URL}" -o "unifont.ttf.zip" \
  && unzip "unifont.ttf.zip" -d "./plugins/ImageGraph/fonts/" \
  && rm -f "unifont.ttf.zip"
WORKDIR /dist/mmdb
RUN curl -fsSLO "${GEOIP_MMDB_BASE_URL}/GeoLite2-ASN.mmdb" \
  && curl -fsSLO "${GEOIP_MMDB_BASE_URL}/GeoLite2-City.mmdb" \
  && curl -fsSLO "${GEOIP_MMDB_BASE_URL}/GeoLite2-Country.mmdb"

FROM alpine:${ALPINE_VERSION}

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS="2" \
  S6_STAGE2_HOOK="/etc/s6-overlay/scripts/runtime-bundles" \
  TZ="UTC" \
  PUID="1000" \
  PGID="1000" \
  MATOMO_PLUGIN_DIRS="/var/www/matomo/data-plugins/;data-plugins" \
  MATOMO_PLUGIN_COPY_DIR="/var/www/matomo/data-plugins/"

COPY --from=gosu /gosu /usr/local/bin/
COPY --from=download --chown=nobody:nogroup /dist/matomo /var/www/matomo
COPY --from=download --chown=nobody:nogroup /dist/mmdb /var/mmdb

RUN apk --update --no-cache upgrade \
  && apk --no-cache add \
    bash \
    ca-certificates \
    curl \
    libmaxminddb \
    nginx \
    nginx-mod-http-brotli \
    openssl \
    php85 \
    php85-bcmath \
    php85-cli \
    php85-ctype \
    php85-curl \
    php85-dom \
    php85-iconv \
    php85-fpm \
    php85-gd \
    php85-gmp \
    php85-json \
    php85-ldap \
    php85-mbstring \
    php85-openssl \
    php85-pdo \
    php85-pdo_mysql \
    php85-pecl-maxminddb \
    php85-redis \
    php85-session \
    php85-simplexml \
    php85-xml \
    php85-zlib \
    rsync \
    s6-overlay \
    shadow \
    tzdata \
  && addgroup -g ${PGID} matomo \
  && adduser -D -H -u ${PUID} -G matomo -h /var/www/matomo  -s /bin/sh matomo \
  && rm -rf /tmp/*

COPY rootfs /

EXPOSE 8000
VOLUME [ "/data" ]

ENTRYPOINT [ "/init" ]

HEALTHCHECK --interval=30s --timeout=20s --start-period=10s \
  CMD /usr/local/bin/healthcheck
