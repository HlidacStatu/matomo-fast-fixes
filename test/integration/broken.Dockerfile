# Image whose healthcheck never passes. Its first probe drops the marker table,
# simulating a migration that damaged the database before the failure.
ARG BASE
FROM ${BASE}
LABEL it.variant=broken
COPY broken-healthcheck.sh /usr/local/bin/healthcheck
RUN chmod 755 /usr/local/bin/healthcheck
