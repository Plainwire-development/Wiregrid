#!/usr/bin/env python3
import subprocess, sys
binary=sys.argv[1] if len(sys.argv)>1 else 'tests/client_test'
server=subprocess.Popen([sys.executable,'tests/mock_gateway.py'],stdout=subprocess.PIPE,text=True)
try:
    port=server.stdout.readline().strip()
    if not port: raise SystemExit('mock gateway failed to start')
    result=subprocess.run([binary,port],check=False)
    server.wait(timeout=2)
    raise SystemExit(result.returncode or server.returncode or 0)
finally:
    if server.poll() is None: server.kill()
