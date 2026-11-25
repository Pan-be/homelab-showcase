"""BookOrbit -> Homepage bridge. Logs in as a native client, keeps the token pair in memory and
serves small JSON documents for Homepage's customapi widget:
  GET /overview  library totals, streak and yearly goal in one flat object
  GET /reading   books in progress: [{title, author, progress}]
Credentials come from BO_USER / BO_PASS and are never logged."""
import json, os, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("BO_URL", "http://bookorbit-app:3000") + "/api/v1"
CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
lock = threading.Lock()
tokens = {"access": None, "refresh": None}
cache = {}


def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def authenticate():
    if tokens["refresh"]:
        try:
            creds = post("/auth/refresh", {"refreshToken": tokens["refresh"]})
            tokens.update(access=creds["accessToken"], refresh=creds["refreshToken"])
            return
        except (urllib.error.URLError, KeyError, ValueError):
            pass
    creds = post("/auth/login", {"username": os.environ["BO_USER"], "password": os.environ["BO_PASS"],
                                 "clientKind": "native", "deviceLabel": "homepage"})
    tokens.update(access=creds["accessToken"], refresh=creds["refreshToken"])


def get(path, retry=True):
    if not tokens["access"]:
        authenticate()
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {tokens['access']}",
                                                       "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry:
            authenticate()
            return get(path, retry=False)
        raise


def overview():
    lib = get("/dashboard/widgets/library-overview")
    streak = get("/dashboard/widgets/reading-streak")
    goal = get("/dashboard/widgets/reading-goal")
    reading = get("/dashboard/widgets/currently-reading")["books"]
    return {**lib, "storageGB": round(lib["totalStorageBytes"] / 1e9, 2),
            "currentStreak": streak["currentStreak"], "longestStreak": streak["longestStreak"],
            "readingNow": len(reading), "finishedThisYear": goal["completedBooks"],
            "goal": f"{goal['completedBooks']}/{goal['goalBooks']}" if goal["goalBooks"] else str(goal["completedBooks"])}


def reading():
    books = get("/dashboard/widgets/currently-reading")["books"]
    return [{"title": b["title"] or "?", "author": ", ".join(b["authors"]),
             "progress": f"{b['progress']:.0f}%"} for b in books]


ROUTES = {"/overview": overview, "/reading": reading}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        fn = ROUTES.get(self.path.split("?")[0])
        if not fn:
            return self.reply(404, {"error": "not found"})
        try:
            with lock:
                hit = cache.get(self.path)
                if not hit or time.time() - hit[0] > CACHE_TTL:
                    hit = cache[self.path] = (time.time(), fn())
            self.reply(200, hit[1])
        except Exception as e:  # report the type only, never request bodies
            self.reply(502, {"error": type(e).__name__})

    def reply(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
