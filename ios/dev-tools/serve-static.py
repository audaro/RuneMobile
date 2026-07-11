#!/usr/bin/env python3
# serve-static.py DIR PORT — tiny threaded static server with HTTP Range/resume support, bound to
# 127.0.0.1 (fronted by `tailscale serve` for tailnet HTTPS). The stdlib http.server ignores Range
# (always 200), so an interrupted IPA download over a flaky phone tunnel restarts from 0 and stalls
# forever. This advertises Accept-Ranges and honors `Range:` (206), so SideStore/URLSession can resume.
import sys, os, re, http.server, socketserver

DIRECTORY = sys.argv[1]
PORT = int(sys.argv[2])
BIND = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"  # pass 0.0.0.0 to expose on the LAN


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=DIRECTORY, **k)

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None
        try:
            st = os.fstat(f.fileno())
            size = st.st_size
            ctype = self.guess_type(path)
            rng = self.headers.get("Range")
            m = re.match(r"bytes=(\d*)-(\d*)\s*$", rng) if rng else None
            if m and (m.group(1) or m.group(2)):
                start = int(m.group(1)) if m.group(1) else 0
                end = int(m.group(2)) if m.group(2) else size - 1
                if start >= size:
                    self.send_error(416, "Requested Range Not Satisfiable")
                    f.close()
                    return None
                end = min(end, size - 1)
                self._send_len = end - start + 1
                self.send_response(206)
                self.send_header("Content-Type", ctype)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.send_header("Content-Length", str(self._send_len))
                self.send_header("Last-Modified", self.date_time_string(st.st_mtime))
                self.end_headers()
                f.seek(start)
                return f
            # full response, but advertise resumability
            self._send_len = size
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(size))
            self.send_header("Last-Modified", self.date_time_string(st.st_mtime))
            self.end_headers()
            return f
        except Exception:
            f.close()
            raise

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_send_len", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        while remaining > 0:
            chunk = source.read(min(262144, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server((BIND, PORT), Handler).serve_forever()
