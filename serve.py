"""Development-only static server. Production deployments should use server.js."""

import http.server
import os
from pathlib import Path

os.chdir(Path(__file__).resolve().parent)
port = int(os.environ.get("PORT", "8080"))
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler)
print(f"MusicTube development site server listening on http://127.0.0.1:{port}")
httpd.serve_forever()
