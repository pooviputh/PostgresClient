#!/bin/sh
# Starts the Postgres the live tests expect, then: PG_TEST_PORT=55432 ceesafec test
#
#   cee / cee_test_pw         SCRAM-SHA-256
#   md5user / md5_pw          md5
#   plainuser / plain_pw      cleartext password
#   tlsonly / tls_pw          SCRAM, refused without TLS
#
# TLS uses the tls package's localhost fixture (SAN localhost and 127.0.0.1, signed by its test CA).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
fixtures="$here/../../../CeeSafeLibs/tls/tests/fixtures"
name=ceesafe-pg-test
port=${PG_TEST_PORT:-55432}

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "127.0.0.1:$port:5432" \
    -e POSTGRES_USER=cee -e POSTGRES_PASSWORD=cee_test_pw -e POSTGRES_DB=ceetest \
    postgres:17-alpine >/dev/null
until docker exec "$name" pg_isready -U cee -d ceetest >/dev/null 2>&1; do sleep 1; done
sleep 2 # the image restarts the server once after initialising

docker cp "$fixtures/localhost.pem" "$name:/var/lib/postgresql/server.crt"
docker cp "$fixtures/localhost.key" "$name:/var/lib/postgresql/server.key"
docker exec -u root "$name" sh -c '
    chown postgres:postgres /var/lib/postgresql/server.*
    chmod 600 /var/lib/postgresql/server.key
    cd "$PGDATA"
    { echo "host all md5user all md5"
      echo "host all plainuser all password"
      echo "hostnossl all tlsonly all reject"
      cat pg_hba.conf; } > hba.new
    mv hba.new pg_hba.conf
    chown postgres pg_hba.conf'

docker exec "$name" psql -q -U cee -d ceetest \
    -c "ALTER SYSTEM SET ssl = on" \
    -c "ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/server.crt'" \
    -c "ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/server.key'" \
    -c "SET password_encryption = 'md5'" \
    -c "CREATE ROLE md5user LOGIN PASSWORD 'md5_pw'" \
    -c "CREATE ROLE plainuser LOGIN PASSWORD 'plain_pw'" \
    -c "SET password_encryption = 'scram-sha-256'" \
    -c "CREATE ROLE tlsonly LOGIN PASSWORD 'tls_pw'" \
    -c "SELECT pg_reload_conf()" >/dev/null
echo "ready: PG_TEST_PORT=$port ceesafec test"
