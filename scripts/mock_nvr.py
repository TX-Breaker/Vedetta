#!/usr/bin/env python3
"""Mock VIGI NVR JSON API for local end-to-end tests (development only).

Implements the subset used by Vedetta: get_encrypt_info, RSA login, device_info,
chm.added_dev, system.get_user_id, playback search (year/day/events), logout.
Video comes from the mediamtx test bench (scripts/test-rtsp-server.sh).

Usage: python3 mock_nvr.py <port> <credentials-file>
"""
import base64, hashlib, json, os, random, ssl, string, subprocess, sys, time, urllib.parse
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
CRED = dict(line.strip().split("=", 1) for line in open(sys.argv[2]) if "=" in line)
USER, PASS = CRED["USER"], CRED["PASS"]
HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(HERE, "testenv")

key1 = rsa.generate_private_key(public_exponent=65537, key_size=1024)
key2 = rsa.generate_private_key(public_exponent=65537, key_size=2048)
def spki(k):
    der = k.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return urllib.parse.quote(base64.b64encode(der).decode(), safe="")

STATE = {"nonce": None, "stok": None, "fails": 0}

def day_segments(day):
    base = datetime(day.year, day.month, day.day)
    segs = [(0, 6 * 3600, 1), (6 * 3600 + 600, 8 * 3600, 1), (8 * 3600, 8 * 3600 + 900, 2),
            (8 * 3600 + 900, 20 * 3600, 1), (20 * 3600 + 1200, 24 * 3600 - 1, 1)]
    now = time.time()
    out = []
    for s, e, t in segs:
        st = base.timestamp() + s
        en = min(base.timestamp() + e, now)
        if en > st:
            out.append({"startTime": int(st), "endTime": int(en), "videoType": t})
    return out

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        body = b"<html><body><h1>Mock VIGI NVR</h1></body></html>"
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        path = self.path
        if path == "/":
            return self.anon(req)
        if path.startswith("/stok="):
            tok = path[len("/stok="):].split("/")[0]
            if tok != STATE["stok"]:
                return self.reply({"error_code": -40401})
            return self.ds(req)
        self.reply({"error_code": -1}, 404)

    def challenge(self):
        STATE["nonce"] = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(8))
        return {"error_code": -40401, "data": {"code": -40401, "encrypt_type": ["1", "2"],
                "key": spki(key1), "key_2": spki(key2), "nonce": STATE["nonce"]}, "device_type": "SECUR.NVR"}

    def anon(self, req):
        if "user_management" in req and "get_encrypt_info" in req["user_management"]:
            return self.reply(self.challenge())
        if "get_device_name" in req:
            return self.reply({"device_name": "VIGI%20NVR2016H(UN)%20MOCK", "error_code": 0})
        if "login" in req:
            lg = req["login"]
            if "password" not in lg:
                return self.reply(self.challenge())
            try:
                blob = base64.b64decode(urllib.parse.unquote(lg["password"]))
                k = key2 if lg.get("keyType") == "1" else key1
                plain = k.decrypt(blob, padding.PKCS1v15()).decode()
            except Exception as e:
                plain = ""
            expected = hashlib.sha256(PASS.encode()).hexdigest().upper() + ":" + (STATE["nonce"] or "")
            if urllib.parse.unquote(lg.get("username", "")) == USER and plain == expected and lg.get("passwdType") == "sha256":
                STATE["stok"] = "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(32))
                STATE["fails"] = 0
                return self.reply({"error_code": 0, "stok": STATE["stok"], "user_group": "root"})
            STATE["fails"] += 1
            return self.reply({"error_code": -40210, "data": {"code": -40210, "sec_left": 0}})
        self.reply({"error_code": -40101})

    def ds(self, req):
        if "device_info" in req:
            return self.reply({"error_code": 0, "device_info": {"info": {".name": "info", "device_model": "VIGI NVR2016H(UN)",
                              "device_name": "NVR%20di%20prova", "sw_version": "1.2.0 Build 240101"}}})
        if "chm" in req and "table" in req["chm"]:
            chans = [
                {"added_dev_1": {"id": "1", "name": "VIGI C340", "alias": "Ingresso", "ip": "10.0.0.11", "online": "1", "auth_result": "0", "connect_prot": "TP-LINK"}},
                {"added_dev_2": {"id": "2", "name": "VIGI C340", "alias": "Giardino", "ip": "10.0.0.12", "online": "1", "auth_result": "0", "connect_prot": "TP-LINK"}},
                {"added_dev_3": {"id": "3", "name": "VIGI C340-W", "alias": "Garage", "ip": "10.0.0.14", "online": "0", "auth_result": "0", "connect_prot": "TP-LINK"}},
            ]
            return self.reply({"error_code": 0, "chm": {"added_dev": chans}})
        if "system" in req:
            if "get_user_id" in req["system"]:
                return self.reply({"error_code": 0, "user_id": 7})
            return self.reply({"error_code": 0})
        if "playback" in req:
            p = req["playback"]
            if "search_year_utility" in p:
                today = datetime.now()
                days = [(today - timedelta(days=i)).strftime("%Y%m%d") for i in range(0, 12) if i != 4]
                return self.reply({"error_code": 0, "playback": {"search_results": [{"search_results_%d" % i: {"date": d}} for i, d in enumerate(days)]}})
            if "search_video_utility" in p:
                q = p["search_video_utility"]
                day = datetime.strptime(q["date"], "%Y%m%d")
                segs = day_segments(day)[q["start_index"]:q["end_index"] + 1]
                return self.reply({"error_code": 0, "playback": {"search_video_results": [{"search_video_results_%d" % i: s} for i, s in enumerate(segs)]}})
            if "search_video_event_playback" in p:
                q = p["search_video_event_playback"]
                st, en = q["start_time"], q["end_time"]
                evs = []
                for h, t in [(8, 1), (8.05, 12), (9.5, 13), (13.25, 3), (17.75, 12)]:
                    s = st + int(h * 3600)
                    if s < min(en, time.time()):
                        evs.append({"startTime": s, "endTime": s + 45, "eventType": str(t)})
                if q.get("start_index", 0) > 0: evs = []
                return self.reply({"error_code": 0, "playback": {"search_video_results": [{"r%d" % i: e} for i, e in enumerate(evs)]}})
        self.reply({"error_code": 0})

if __name__ == "__main__":
    cert, key = os.path.join(ENV, "mock.crt"), os.path.join(ENV, "mock.key")
    if not os.path.exists(cert):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                        "-days", "30", "-subj", "/CN=mock-nvr"], check=True, capture_output=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print("mock NVR on https://127.0.0.1:%d" % PORT, flush=True)
    srv.serve_forever()
