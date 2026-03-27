#!/bin/bash

echo "[init] Waiting for ClickHouse..."
for i in $(seq 1 30); do
  clickhouse-client --host 127.0.0.1 --query "SELECT 1" 2>/dev/null && break
  sleep 2
done

echo "[init] Applying schema..."
clickhouse-client --host 127.0.0.1 --multiquery --multiline < /docker-entrypoint-initdb.d/01_schema.sql 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "[init] Schema applied successfully."
  # Verify tables exist
  clickhouse-client --host 127.0.0.1 --database spectabas --query "SHOW TABLES" 2>&1
else
  echo "[init] Schema failed with exit code $EXIT_CODE"
fi
