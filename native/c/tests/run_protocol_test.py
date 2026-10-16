#!/usr/bin/env python3
import subprocess, sys
from adversarial_test import run
binary=sys.argv[1] if len(sys.argv)>1 else 'tests/client_test'
server=subprocess.Popen([sys.executable,'tests/mock_gateway.py'],stdout=subprocess.PIPE,text=True)
try:
    port=server.stdout.readline().strip()
    if not port: raise SystemExit('mock gateway failed to start')
    result=subprocess.run([binary,port],check=False,timeout=10)
    server.wait(timeout=2)
    if result.returncode or server.returncode:
        raise SystemExit(result.returncode or server.returncode)
    run(binary)
finally:
    if server.poll() is None: server.kill()
