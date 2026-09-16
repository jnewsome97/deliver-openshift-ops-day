#!/bin/bash
# Test DNS connectivity to 8.8.8.8 from inside a pod
# Uses python3 to send an actual DNS query and wait for response
NAMESPACE="${1:-netpol-backend}"
DEPLOYMENT="${2:-backend}"

oc exec -n "$NAMESPACE" "deployment/$DEPLOYMENT" -- python3 -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    q = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06google\x03com\x00\x00\x01\x00\x01'
    s.sendto(q, ('8.8.8.8', 53))
    data, addr = s.recvfrom(512)
    print('DNS to 8.8.8.8: ALLOWED')
except socket.timeout:
    print('DNS to 8.8.8.8: BLOCKED (timed out)')
except Exception as e:
    print(f'DNS to 8.8.8.8: ERROR ({e})')
finally:
    s.close()
"
