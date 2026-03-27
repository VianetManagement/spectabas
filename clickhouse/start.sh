#!/bin/bash
# Run schema init in background after ClickHouse starts
/init-schema.sh &

# Start ClickHouse (this is the main process)
exec /entrypoint.sh
