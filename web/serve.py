#!/usr/bin/env python3
"""Serve build/web/ (scripts/build_web.sh) with the cross-origin isolation headers that
SharedArrayBuffer (the emulator's threads) needs:
  http://127.0.0.1:8765/        this machine only
  https://<LAN address>:8766/   other computers, when web/makecert.sh has made build/web-cert/
                                (browsers allow the page's features only on localhost or HTTPS)
Also runs the lobby server for online play (web/netplay/signaling.py) and forwards /net/ws to it."""
import asyncio, http.server, os, functools, socket, ssl, sys, threading

# The headers the page is written for, including a strict Content-Security-Policy.
CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; "
       "style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
HEADERS = {
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Content-Security-Policy': CSP,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), usb=(), hid=(), serial=(), payment=()',
}

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm', '.js': 'text/javascript',
                      '.lua': 'text/plain; charset=utf-8'}

    def do_GET(self):
        if self.path == '/net/ws':
            self.forward_websocket()
        else:
            super().do_GET()

    def forward_websocket(self):
        # the lobby server (web/netplay/signaling.py, started below), as nginx does on the site
        try:
            up = socket.create_connection(('127.0.0.1', SIGNAL_PORT), timeout=5)
        except OSError:
            self.send_error(502)
            return
        up.settimeout(None)
        head = f'GET {self.path} HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in self.headers.items() if k.lower() != 'x-real-ip')
        head += f'X-Real-IP: {self.client_address[0]}\r\n\r\n'
        up.sendall(head.encode('latin-1'))

        def pipe(src, dst):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

        t = threading.Thread(target=pipe, args=(up, self.connection), daemon=True)
        t.start()
        pipe(self.connection, up)
        t.join()
        up.close()
        self.close_connection = True

    def end_headers(self):
        for name, value in HEADERS.items():
            self.send_header(name, value)
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIGNAL_PORT = 8767
sys.path.insert(0, os.path.join(root, 'web', 'netplay'))
import signaling
threading.Thread(target=lambda: asyncio.run(signaling.main('127.0.0.1', SIGNAL_PORT)), daemon=True).start()
site = os.path.join(root, 'build', 'web')
if not os.path.exists(os.path.join(site, 'mesen.wasm')):
    raise SystemExit('build/web is not built: run scripts/build_web.sh')
handler = functools.partial(Handler, directory=site)

local = http.server.ThreadingHTTPServer(('127.0.0.1', 8765), handler)
threading.Thread(target=local.serve_forever, daemon=True).start()
print('http://127.0.0.1:8765/', flush=True)

cert = os.path.join(root, 'build', 'web-cert', 'cert.pem')
key = os.path.join(root, 'build', 'web-cert', 'key.pem')
if os.path.exists(cert):
    lan = http.server.ThreadingHTTPServer(('0.0.0.0', 8766), handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    lan.socket = ctx.wrap_socket(lan.socket, server_side=True)
    print('https://<this machine>:8766/ (self-signed: accept the warning once)', flush=True)
    lan.serve_forever()
else:
    print('LAN server off: run web/makecert.sh to enable https://<this machine>:8766/', flush=True)
    threading.Event().wait()
