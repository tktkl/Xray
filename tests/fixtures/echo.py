import http.server
import itertools
import socket
import socketserver
import threading
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        if self.path == '/stream':
            try:
                # The test controls the lifetime. A fixed 60-second response
                # expires during slower CI runs and falsely looks like a drop.
                for i in itertools.count():
                    self.wfile.write(('%s %d\n' % (self.client_address[0], i)).encode())
                    self.wfile.flush()
                    time.sleep(.1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.wfile.write(self.client_address[0].encode())
    def log_message(self, *args):
        pass

class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)

class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        data=self.request.recv(4096)
        if data:self.request.sendall(data)

class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address=True

threading.Thread(target=lambda:socketserver.ThreadingUDPServer(('0.0.0.0',18081),UDP).serve_forever(),daemon=True).start()
threading.Thread(target=lambda:TCPServer(('0.0.0.0',18082),TCP).serve_forever(),daemon=True).start()
http.server.ThreadingHTTPServer(('0.0.0.0',18080),Handler).serve_forever()
