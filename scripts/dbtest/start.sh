#!/bin/zsh
# Starts throwaway PostgreSQL and MySQL servers for the database explorer's integration tests
# (OhMyCodeTests/DatabaseServerTests.swift), in a temporary folder of their own, on free ports.
# Nothing of Homebrew's own data folders or services is touched.
#
#   eval "$(scripts/dbtest/start.sh)"     # exports OMC_TEST_* and OMC_DBTEST_DIR
#   scripts/dbtest/stop.sh "$OMC_DBTEST_DIR"
#
# Postgres: users omc (SCRAM-SHA-256), omc_md5 (MD5), omc_plain (cleartext password), TLS on
# with a self-signed certificate for "localhost". MySQL: omc_sha2 (caching_sha2_password) and,
# when the server still has it, omc_native (mysql_native_password); TLS with the server's own
# generated certificates.
#
# Prints shell `export` lines on stdout; progress goes to stderr. On failure everything it
# started is stopped again.
set -euo pipefail

PG_BIN=${OMC_PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}
MYSQL_BIN=${OMC_MYSQL_BIN:-/opt/homebrew/bin}
HERE=${0:A:h}

say() { print -u2 -- "dbtest: $*" }

free_port() {
  local port
  while true; do
    port=$(( 20000 + RANDOM % 30000 ))
    if ! lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
      print -- $port
      return
    fi
  done
}

DIR=$(mktemp -d "${TMPDIR:-/tmp}/omc-dbtest.XXXXXX")
DIR=${DIR:A}
trap 'say "failed; cleaning up"; "$HERE/stop.sh" "$DIR" >&2 || true' ERR

# MARK: PostgreSQL

PG_PORT=$(free_port)
PG_DATA=$DIR/pg
print -- "pgpass" > $DIR/pwfile
say "initdb (postgres on $PG_PORT)"
$PG_BIN/initdb -D $PG_DATA -U omc --auth=scram-sha-256 --pwfile=$DIR/pwfile -E UTF8 --locale=C >$DIR/initdb.log 2>&1

# A certificate authority of its own, and the server's certificate signed by it.
openssl req -new -x509 -days 2 -nodes -newkey rsa:2048 -subj "/CN=Oh My Code Test CA" \
  -keyout $DIR/ca.key -out $DIR/pg-root.crt >/dev/null 2>&1
openssl req -new -nodes -newkey rsa:2048 -subj "/CN=localhost" -keyout $PG_DATA/server.key -out $DIR/server.csr >/dev/null 2>&1
print -- "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE" > $DIR/server.ext
openssl x509 -req -days 2 -in $DIR/server.csr -CA $DIR/pg-root.crt -CAkey $DIR/ca.key -CAcreateserial -CAserial $DIR/ca.srl \
  -extfile $DIR/server.ext -out $PG_DATA/server.crt >/dev/null 2>&1
chmod 600 $PG_DATA/server.key

cat >> $PG_DATA/postgresql.conf <<EOF
port = $PG_PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '$DIR'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
fsync = off
EOF

cat > $PG_DATA/pg_hba.conf <<EOF
local all all trust
host all omc_md5 127.0.0.1/32 md5
host all omc_plain 127.0.0.1/32 password
host all all 127.0.0.1/32 scram-sha-256
EOF

$PG_BIN/pg_ctl -D $PG_DATA -l $DIR/postgres.log -w -t 30 start >/dev/null
PSQL=($PG_BIN/psql -h $DIR -p $PG_PORT -U omc -d postgres -v ON_ERROR_STOP=1 -q)
$PSQL -c "CREATE DATABASE omc_test"
$PSQL -c "SET password_encryption = 'md5'; CREATE ROLE omc_md5 LOGIN PASSWORD 'md5pass'" 2>/dev/null
$PSQL -c "CREATE ROLE omc_plain LOGIN PASSWORD 'plainpass'"
$PSQL -c "GRANT ALL ON DATABASE omc_test TO omc_md5, omc_plain"
$PG_BIN/psql -h $DIR -p $PG_PORT -U omc -d omc_test -q -v ON_ERROR_STOP=1 -c "GRANT ALL ON SCHEMA public TO omc_md5, omc_plain"

# MARK: MySQL

MY_PORT=$(free_port)
while [[ $MY_PORT == $PG_PORT ]]; do MY_PORT=$(free_port); done
MY_DATA=$DIR/mysql
MY_SOCK=$DIR/mysql.sock
say "mysqld --initialize-insecure (mysql on $MY_PORT)"
$MYSQL_BIN/mysqld --no-defaults --initialize-insecure --datadir=$MY_DATA >$DIR/mysql-init.log 2>&1
$MYSQL_BIN/mysqld --no-defaults --datadir=$MY_DATA --port=$MY_PORT --bind-address=127.0.0.1 --socket=$MY_SOCK \
  --pid-file=$DIR/mysqld.pid --mysqlx=OFF --log-error=$DIR/mysqld.err >/dev/null 2>&1 &!
for i in {1..60}; do
  $MYSQL_BIN/mysqladmin --no-defaults --socket=$MY_SOCK -uroot ping >/dev/null 2>&1 && break
  sleep 0.5
done
$MYSQL_BIN/mysqladmin --no-defaults --socket=$MY_SOCK -uroot ping >/dev/null 2>&1
MYSQL=($MYSQL_BIN/mysql --no-defaults --socket=$MY_SOCK -uroot)
$MYSQL -e "CREATE DATABASE omc_test; CREATE USER 'omc_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'sha2pass'; GRANT ALL ON *.* TO 'omc_sha2'@'%'"
NATIVE=""
if $MYSQL -e "CREATE USER 'omc_native'@'%' IDENTIFIED WITH mysql_native_password BY 'nativepass'; GRANT ALL ON omc_test.* TO 'omc_native'@'%'" 2>/dev/null; then
  NATIVE=1
else
  say "this MySQL has no mysql_native_password: skipping that user"
fi

cat > $DIR/env.sh <<EOF
export OMC_DBTEST_DIR='$DIR'
export OMC_TEST_POSTGRES_URL='postgres://omc:pgpass@127.0.0.1:$PG_PORT/omc_test?sslmode=disable'
export OMC_TEST_POSTGRES_MD5_URL='postgres://omc_md5:md5pass@127.0.0.1:$PG_PORT/omc_test?sslmode=disable'
export OMC_TEST_POSTGRES_PLAIN_URL='postgres://omc_plain:plainpass@127.0.0.1:$PG_PORT/omc_test?sslmode=disable'
export OMC_TEST_POSTGRES_TLS_URL='postgres://omc:pgpass@localhost:$PG_PORT/omc_test?sslmode=verify-full&sslrootcert=$DIR/pg-root.crt'
export OMC_TEST_MYSQL_URL='mysql://omc_sha2:sha2pass@127.0.0.1:$MY_PORT/omc_test?sslmode=disable'
export OMC_TEST_MYSQL_TLS_URL='mysql://omc_sha2:sha2pass@127.0.0.1:$MY_PORT/omc_test?sslmode=require'
EOF
if [[ -n $NATIVE ]]; then
  print -- "export OMC_TEST_MYSQL_NATIVE_URL='mysql://omc_native:nativepass@127.0.0.1:$MY_PORT/omc_test?sslmode=disable'" >> $DIR/env.sh
fi
trap - ERR
say "ready in $DIR"
cat $DIR/env.sh
