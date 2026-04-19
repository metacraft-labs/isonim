#!/bin/bash
set -e

cd "$(dirname "$0")"

# Start mock DB
nim c -r --mm:orc mock_db.nim 9876 &
DB_PID=$!
sleep 1

# Start streaming server
nim c -r --mm:orc server.nim 9876 8090 &
SERVER_PID=$!
sleep 2

# Send test requests
echo "Sending 3 requests..."
for i in 1 2 3; do
  curl -s http://localhost:8090/streaming-page > /tmp/streaming_response_$i.html &
done
wait

# Verify responses
for i in 1 2 3; do
  if grep -q "Streaming Dashboard" /tmp/streaming_response_$i.html; then
    echo "Request $i: OK"
  else
    echo "Request $i: FAILED"
  fi
done

# Cleanup
kill $SERVER_PID $DB_PID 2>/dev/null
rm -f /tmp/streaming_response_*.html
echo "Done."
