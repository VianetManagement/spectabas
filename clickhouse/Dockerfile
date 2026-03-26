FROM clickhouse/clickhouse-server:24.3-alpine

COPY schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY clickhouse-users.xml /etc/clickhouse-server/users.d/spectabas.xml

ENV CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1

# Render expects port 10000, so configure ClickHouse HTTP to use it
RUN echo '<clickhouse><http_port>10000</http_port></clickhouse>' > /etc/clickhouse-server/config.d/port.xml

EXPOSE 10000
