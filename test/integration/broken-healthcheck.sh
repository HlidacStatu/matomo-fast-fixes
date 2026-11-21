#!/bin/sh
# Healthcheck of the "broken" integration test image: damages the database,
# then reports the container as unhealthy.
if [ "$SIDECAR_CRON" != "1" ]; then
  php -r '
    $pdo = new PDO("mysql:host=db;dbname=matomo", "matomo", getenv("IT_DB_PASSWORD"));
    $pdo->exec("DROP TABLE IF EXISTS it_marker");
  ' >/dev/null 2>&1 || true
fi
exit 1
