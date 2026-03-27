#!/bin/bash
set -e

# Wait for ClickHouse to start
until clickhouse-client --host localhost --port 9000 --query "SELECT 1" 2>/dev/null; do
  sleep 1
done

echo "Running schema initialization..."
clickhouse-client --host localhost --port 9000 --multiquery < /docker-entrypoint-initdb.d/01_schema.sql
echo "Schema initialization complete."
