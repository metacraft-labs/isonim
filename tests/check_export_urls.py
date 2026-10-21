"""No mocks: serve the actual exporter tree over HTTP and read every HTML file."""
import functools
import http.server
import pathlib
import sys
import threading
import urllib.parse
import urllib.request

root = pathlib.Path(sys.argv[1])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        pages = sorted(root.rglob("index.html"))
        assert len(pages) == 7, pages
        assert any("~2e2e2f252c3dcebb" in str(page) for page in pages)
        for page in pages:
            route = "/" + page.relative_to(root).as_posix().removesuffix("index.html")
            for safe in ["/", "/~=,"]:
                url = f"http://127.0.0.1:{server.server_port}" + urllib.parse.quote(route, safe=safe)
                with urllib.request.urlopen(url) as response:
                    assert response.status == 200
                    assert response.read() == page.read_bytes()
    finally:
        server.shutdown()
        thread.join()
