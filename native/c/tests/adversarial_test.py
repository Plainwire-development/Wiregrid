"""Black-box stream regressions against deliberately hostile TCP peers."""
import socket
import struct
import subprocess
import threading
import time


def frame(kind, op, rid, fields):
    body = bytes([1, kind, op]) + struct.pack(">I", rid)
    for tag, data in fields:
        body += bytes([tag]) + struct.pack(">I", len(data)) + data
    return struct.pack(">I", len(body)) + body


def exact(sock, length):
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise EOFError("client closed")
        data.extend(chunk)
    return bytes(data)


def request(sock):
    length = struct.unpack(">I", exact(sock, 4))[0]
    data = exact(sock, length)
    assert data[:2] == b"\x01\x00"
    return data[2], struct.unpack(">I", data[3:7])[0]


def serve(listener, scenario, errors):
    try:
        with listener.accept()[0] as sock:
            sock.settimeout(3)
            op, rid = request(sock)
            assert op == 1
            sock.sendall(frame(1, op, rid, [(7, b"ok"), (13, b"s1")]))
            op, rid = request(sock)
            response = frame(1, op, rid, [(7, b"ok"), (12, b"1.0.0")])
            event = frame(2, 64, 0, [(3, b"general"), (4, b"fragmented")])
            if scenario.startswith("partial_"):
                assert op == 2
                split = 2 if scenario == "partial_header" else 17
                sock.sendall(frame(1, op, rid, [(7, b"ok")]) + event[:split])
                op, rid = request(sock)
                assert op == 9
                sock.sendall(event[split:] + frame(1, op, rid, [(7, b"ok")]))
            elif scenario == "slow_response":
                for byte in response:
                    sock.sendall(bytes([byte]))
                    time.sleep(0.025)
            elif scenario == "event_flood":
                for _ in range(40):
                    sock.sendall(event)
                    time.sleep(0.025)
                sock.sendall(response)
            elif scenario == "history_buffers":
                for _ in range(3):
                    assert op == 10
                    sock.sendall(frame(1, op, rid, [(7, b"ok"), (4, b'{"events":[]}'), (15, b"cursor-1")]))
                    op, rid = request(sock)
                assert op == 9
                sock.sendall(frame(1, op, rid, [(7, b"ok")]))
            elif scenario == "bad_length":
                sock.sendall(struct.pack(">I", 2 * 1024 * 1024 + 1))
            elif scenario == "duplicate_fields":
                sock.sendall(frame(1, op, rid, [(7, b"ok"), (7, b"ok")]))
            elif scenario == "zero_tag":
                sock.sendall(frame(1, op, rid, [(7, b"ok"), (0, b"ignored")]))
            elif scenario == "bad_status":
                sock.sendall(frame(1, op, rid, [(7, b"maybe")]))
            elif scenario == "missing_status":
                sock.sendall(frame(1, op, rid, []))
            elif scenario == "bad_event":
                sock.sendall(frame(2, 9, rid, [(3, b"general"), (4, b"bad")]))
            elif scenario == "wrong_response":
                sock.sendall(frame(1, op, rid + 1, [(7, b"ok")]))
            elif scenario == "remote_error":
                sock.sendall(frame(1, op, rid, [(7, b"error"), (10, b"denied")]))
            elif scenario == "final_response":
                sock.sendall(response)
                sock.shutdown(socket.SHUT_WR)
            else:
                raise AssertionError(scenario)
    except (BrokenPipeError, ConnectionResetError):
        if scenario not in ("slow_response", "event_flood"):
            errors.append(f"{scenario}: unexpected stream reset")
    except Exception as error:
        errors.append(f"{scenario}: {error!r}")


def run(binary):
    scenarios = [
        "partial_header", "partial_body", "slow_response", "event_flood",
        "history_buffers", "bad_length", "duplicate_fields", "zero_tag",
        "bad_status", "missing_status", "bad_event", "wrong_response",
        "remote_error", "final_response",
    ]
    for scenario in scenarios:
        errors = []
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(4)
            server = threading.Thread(target=serve, args=(listener, scenario, errors), daemon=True)
            server.start()
            result = subprocess.run([binary, str(listener.getsockname()[1]), scenario], timeout=5, check=False)
            server.join(timeout=4)
            if result.returncode or errors or server.is_alive():
                raise SystemExit(f"C regression {scenario} failed: code={result.returncode} errors={errors}")
    print(f"wiregrid C stream regressions: {len(scenarios)} passed")
