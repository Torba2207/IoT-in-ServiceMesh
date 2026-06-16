import socket
import time

LISTEN_IP = "0.0.0.0"
LISTEN_PORT = 31700

TARGET_IP = "10.29.16.101"
TARGET_PORT = 31700

TARGET = (TARGET_IP, TARGET_PORT)

PKT_TYPES = {
    0x00: "PUSH_DATA",
    0x01: "PUSH_ACK",
    0x02: "PULL_DATA",
    0x03: "PULL_RESP",
    0x04: "PULL_ACK",
    0x05: "TX_ACK",
}

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((LISTEN_IP, LISTEN_PORT))

# Last known gateway addresses by Semtech packet flow.
last_push_addr = None
last_pull_addr = None

# Token map: token -> gateway source address.
pending = {}

def pkt_type(data: bytes):
    if len(data) >= 4:
        return data[3]
    return None

def token(data: bytes):
    if len(data) >= 3:
        return data[1:3]
    return None

def name(t):
    return PKT_TYPES.get(t, f"UNKNOWN_{t}")

print(f"Listening on {LISTEN_IP}:{LISTEN_PORT}")
print(f"Forwarding to {TARGET_IP}:{TARGET_PORT}")

while True:
    data, addr = sock.recvfrom(65535)
    t = pkt_type(data)
    tok = token(data)

    # Packet from ChirpStack Gateway Bridge / server.
    if addr[0] == TARGET_IP:
        if t == 0x01:  # PUSH_ACK
            dst = pending.get(tok, last_push_addr)
        elif t == 0x04:  # PULL_ACK
            dst = pending.get(tok, last_pull_addr)
        elif t == 0x03:  # PULL_RESP: real downlink, must go to PULL_DATA port
            dst = last_pull_addr
        else:
            dst = last_pull_addr or last_push_addr

        if dst is None:
            print(f"server -> ? | {len(data)} bytes | {name(t)} | no gateway addr known, dropped")
            continue

        print(f"server -> gateway | {len(data)} bytes | {name(t)} | {addr} -> {dst}")
        sock.sendto(data, dst)
        continue

    # Packet from Milesight gateway.
    if t == 0x00:  # PUSH_DATA
        last_push_addr = addr
        if tok:
            pending[tok] = addr
    elif t == 0x02:  # PULL_DATA
        last_pull_addr = addr
        if tok:
            pending[tok] = addr
    elif t == 0x05:  # TX_ACK
        # Gateway confirms or rejects radio transmission.
        pass

    print(f"gateway -> server | {len(data)} bytes | {name(t)} | {addr} -> {TARGET}")
    sock.sendto(data, TARGET)

    # Very small cleanup to avoid unbounded growth.
    if len(pending) > 1000:
        pending.clear()