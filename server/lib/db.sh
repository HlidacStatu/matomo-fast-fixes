#!/usr/bin/env bash
# Database helpers shared by the server scripts.
#
# A rollback restores the pre-update dump only when the update actually
# changed the database structure. Restoring unconditionally would discard
# every visit tracked between the backup and the rollback; when nothing was
# migrated, the running database is already the correct state.
#
# The fingerprint covers what Matomo migrations change:
#   - table and column definitions and indexes (only the monthly
#     archive_numeric_* / archive_blob_* tables are excluded: archiving creates
#     them continuously; archive_invalidations and every other table count),
#   - the `version_*` options in which Matomo records core and plugin schema
#     versions (only when Matomo is installed).
# It cannot see data-only changes or a migration interrupted before it
# touched the schema, so a fingerprint match alone is trusted only when the
# Matomo version did not change (see db_restore_needed).

# Shell snippet run inside a MariaDB container: picks the client binary
# (mariadb in current images, mysql in old ones) and connects with the
# application credentials from the container environment.
# shellcheck disable=SC2016,SC2034
DB_CLIENT_SNIPPET='client=mariadb; command -v mariadb >/dev/null 2>&1 || client=mysql
MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$client" -N -B \
  -u"${MARIADB_USER:-$MYSQL_USER}" "${MARIADB_DATABASE:-$MYSQL_DATABASE}"'

# Shell snippet run inside a MariaDB container: dumps the application
# database (mariadb-dump in current images, mysqldump before 10.4).
# shellcheck disable=SC2016,SC2034
DB_DUMP_SNIPPET='dump=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || dump=mysqldump
MYSQL_PWD="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}" exec "$dump" \
  --single-transaction --quick --add-drop-database \
  -u"${MARIADB_USER:-$MYSQL_USER}" --databases "${MARIADB_DATABASE:-$MYSQL_DATABASE}"'

# db_restore_needed PRE_FINGERPRINT POST_FINGERPRINT SAME_MATOMO_VERSION(true|false)
# Succeeds when a rollback must restore the dump: always after a Matomo
# version change (its migrations may have changed data or been interrupted
# before touching the schema; tracking was down anyway, so little is lost),
# when the fingerprint could not be computed, or when it changed.
db_restore_needed() {
  [[ $3 == true ]] || return 0
  [[ -n $1 && -n $2 && $1 == "$2" ]] && return 1
  return 0
}

# db_fingerprint_sql TABLE_PREFIX INSTALLED(true|false)
# Prints the SQL that returns one MD5 fingerprint of the schema.
db_fingerprint_sql() {
  local prefix=$1 installed=$2 like_prefix options_part="''" rotating
  [[ $prefix =~ ^[A-Za-z0-9_]*$ ]] || return 1
  like_prefix=${prefix//_/\\_}
  rotating="table_name NOT LIKE '${like_prefix}archive\\_numeric\\_%' AND table_name NOT LIKE '${like_prefix}archive\\_blob\\_%'"
  if [[ $installed == true ]]; then
    options_part="IFNULL((SELECT GROUP_CONCAT(CONCAT(option_name, '=', option_value)
        ORDER BY option_name SEPARATOR '|')
      FROM \`${prefix}option\` WHERE option_name LIKE 'version\\_%'), '')"
  fi
  cat <<EOF
SET SESSION group_concat_max_len = 1073741824;
SELECT MD5(CONCAT(
  IFNULL((SELECT GROUP_CONCAT(CONCAT_WS(':', table_name, column_name, column_type,
        is_nullable, IFNULL(column_default, 'NULL'))
      ORDER BY table_name, ordinal_position SEPARATOR '|')
    FROM information_schema.columns
    WHERE table_schema = DATABASE() AND ${rotating}), ''),
  '#',
  IFNULL((SELECT GROUP_CONCAT(CONCAT_WS(':', table_name, index_name, non_unique,
        seq_in_index, column_name, IFNULL(sub_part, 'NULL'))
      ORDER BY table_name, index_name, seq_in_index SEPARATOR '|')
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND ${rotating}), ''),
  '#', ${options_part}));
EOF
}

# Prints the SQL that counts base tables not using InnoDB (their dump is not
# covered by --single-transaction).
db_non_innodb_sql() {
  cat <<'EOF'
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' AND engine <> 'InnoDB';
EOF
}

# Prints the SQL that returns the size of the database in bytes.
db_size_sql() {
  cat <<'EOF'
SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables
WHERE table_schema = DATABASE();
EOF
}
