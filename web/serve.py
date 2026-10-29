#!/usr/bin/env python3
"""Serve build/web/ (scripts/build_web.sh) with the cross-origin isolation headers that
SharedArrayBuffer (the emulator's threads) needs:
  http://127.0.0.1:8765/        this machine only
  https://<LAN address>:8766/   other computers, when web/makecert.sh has made build/web-cert/
                                (browsers allow the page's features only on localhost or HTTPS)"""
import http.server, os, functools, ssl, threading

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

    def end_headers(self):
        for name, value in HEADERS.items():
            self.send_header(name, value)
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
