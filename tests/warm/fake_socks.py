#!/usr/bin/env python3
"""A stand-in for xray's helper SOCKS inbound and the site behind it, for
tests/warm.sh: SOCKS5 with user/password on 127.0.0.1:12782; after CONNECT it
answers HTTP itself. What a server does depends on the user (the server tag):

  n-fast   the first request waits 300 ms (the handshakes), later ones 20 ms
  n-slow   300 ms, then 120 ms
  n-dead   SOCKS works, HTTP never answers
  n-503    answers 503
  n-close  answers with "Connection: close" (no keep-alive)
  other    SOCKS refuses the user

Writes a line per new connection and per request to the log given as argv[1].
"""

import socket
import sys
import threading
import time

LOG = open(sys.argv[1], 'a', buffering=1)
lock = threading.Lock()


def log(s):
    with lock:
        LOG.write(s + '\n')


def recv_exact(c, n):
    b = b''
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise EOFError
        b += d
    return b


def handle(c):
    try:
        greet = recv_exact(c, 2)
        if greet[0] != 5:
            return
        recv_exact(c, greet[1])
        c.sendall(b'\x05\x02')
        recv_exact(c, 1)
        user = recv_exact(c, recv_exact(c, 1)[0]).decode()
        pw = recv_exact(c, recv_exact(c, 1)[0]).decode()
        if pw != 'mayhem' or user not in ('n-fast', 'n-slow', 'n-dead', 'n-503', 'n-close'):
            c.sendall(b'\x01\x01')
            return
        c.sendall(b'\x01\x00')
        head = recv_exact(c, 5)
        recv_exact(c, head[4] + 2)
        c.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
        log('connect %s' % user)
        first = True
        buf = b''
        while True:
            while b'\r\n\r\n' not in buf:
                d = c.recv(4096)
                if not d:
                    return
                buf += d
            buf = buf.split(b'\r\n\r\n', 1)[1]
            log('request %s' % user)
            if user == 'n-dead':
                time.sleep(60)
                return
            delay = {'n-fast': (0.3, 0.02), 'n-slow': (0.3, 0.12)}.get(user, (0.05, 0.05))
            time.sleep(delay[0] if first else delay[1])
            first = False
            if user == 'n-503':
                c.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 5\r\n\r\nerror')
            elif user == 'n-close':
                c.sendall(b'HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n')
                return
            else:
                c.sendall(b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n')
    except (EOFError, OSError):
        pass
    finally:
        c.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 12782))
s.listen(64)
log('listening')
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
