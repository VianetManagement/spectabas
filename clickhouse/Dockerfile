FROM clickhouse/clickhouse-server:24.3-alpine

COPY schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY clickhouse-users.xml /etc/clickhouse-server/users.d/spectabas.xml
COPY port-override.xml /etc/clickhouse-server/config.d/port-override.xml

ENV CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1

EXPOSE 10000
