FROM clickhouse/clickhouse-server:24.3

COPY schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY clickhouse-users.xml /etc/clickhouse-server/users.d/spectabas.xml
COPY port-override.xml /etc/clickhouse-server/config.d/port-override.xml
COPY init-schema.sh /init-schema.sh
COPY start.sh /start.sh

RUN chmod +x /init-schema.sh /start.sh

ENV CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1

EXPOSE 10000

CMD ["/start.sh"]
