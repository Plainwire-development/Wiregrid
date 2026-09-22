#!/usr/bin/env python3
import socket, struct, sys
V=1; REQUEST=0; RESPONSE=1; EVENT=2
STATUS=7; ERROR=10; TOPIC=3; PAYLOAD=4; CONTENT=5; DELIVERY=6; EVENT_ID=9; SERVER_VERSION=12; SESSION=13

def fields(blob):
    out={}; i=0
    while i<len(blob):
        tag=blob[i]; n=struct.unpack('>I',blob[i+1:i+5])[0]; i+=5
        if tag in out or i+n>len(blob): raise RuntimeError('bad tlv')
        out[tag]=blob[i:i+n]; i+=n
    return out

def frame(kind, op, rid, fs):
    body=b''.join(bytes([tag])+struct.pack('>I',len(value))+value for tag,value in fs)
    return bytes([V,kind,op])+struct.pack('>I',rid)+body

def send(sock, payload): sock.sendall(struct.pack('>I',len(payload))+payload)
def recv(sock):
    hdr=sock.recv(4)
    if len(hdr)!=4: raise EOFError
    n=struct.unpack('>I',hdr)[0]; data=b''
    while len(data)<n:
        chunk=sock.recv(n-len(data))
        if not chunk: raise EOFError
        data+=chunk
    if data[0]!=V or data[1]!=REQUEST: raise RuntimeError('bad header')
    return data[2], struct.unpack('>I',data[3:7])[0], fields(data[7:])

srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); srv.bind(('127.0.0.1',0)); srv.listen(1)
print(srv.getsockname()[1], flush=True)
conn,_=srv.accept()
try:
    op,rid,fs=recv(conn); assert op==1 and fs[2]==b'alice'
    send(conn, frame(RESPONSE,op,rid,[(STATUS,b'ok'),(SESSION,b's-1'),(SERVER_VERSION,b'1.0.0')]))
    op,rid,fs=recv(conn); assert op==2 and fs[TOPIC]==b'general'
    send(conn, frame(RESPONSE,op,rid,[(STATUS,b'ok')]))
    op,rid,fs=recv(conn); assert op==4 and fs[PAYLOAD]==b'hello'
    send(conn, frame(EVENT,64,0,[(TOPIC,b'general'),(PAYLOAD,b'welcome'),(CONTENT,b'text/plain'),(DELIVERY,b'delivery-1'),(EVENT_ID,b'event-remote')]))
    send(conn, frame(RESPONSE,op,rid,[(STATUS,b'ok'),(EVENT_ID,b'evt-1')]))
    op,rid,fs=recv(conn); assert op==9
    send(conn, frame(RESPONSE,op,rid,[(STATUS,b'ok'),(SERVER_VERSION,b'1.0.0')]))
finally:
    conn.close(); srv.close()
