#!/usr/bin/env python3
"""StreamFlow DLNA 模拟电视（CI/本地 iOS 模拟器测试用；仓库版，源自 testenv/dlna-mock.py）。

- SSDP：bind 0.0.0.0:1900 + 加入 239.255.255.250 组 → 同时响应**组播与单播** M-SEARCH
  （UPnP 1.1 单播发现合法；CI 模拟器用单播路径最稳）
- LOCATION 动态按请求方本机视角 IP 生成（CI 无固定局域网 IP）
- HTTP 0.0.0.0:8091：/description.xml（controlURL=/control，与 LOCATION 同主机 → R-15）
  /control：SOAP AVTransport 状态机 SetURI→Play→PLAYING、Pause→PAUSED_PLAYBACK、
  Stop→STOPPED；GetPositionInfo 返回随播放推进的 RelTime（进度可观测）
用法：python3 dev_dlna_mock.py [--port 8091]
"""
import argparse
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MCAST_GRP = "239.255.255.250"
SSDP_PORT = 1900
HTTP_PORT = 8091
DESCRIPTION = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>StreamFlow Mock TV</friendlyName>
<manufacturer>StreamFlow Test</manufacturer>
<modelName>MockTV-1</modelName>
<UDN>uuid:streamflow-mock-tv-1</UDN>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
<controlURL>/control</controlURL>
<eventSubURL>/event</eventSubURL>
</service>
</serviceList>
</device>
</root>"""

LOCK = threading.RLock()  # 可重入：GetPositionInfo 分支在持锁时调用 reltime()
STATE = {"uri_set": False, "played": False, "paused": False, "played_at": 0.0}
DURATION_SEC = 120


def soap(action, inner):
    return (f'<?xml version="1.0" encoding="utf-8"?>'
            f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            f'<s:Body><u:{action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
            f'{inner}</u:{action}Response></s:Body></s:Envelope>').encode()


def hms(sec):
    sec = max(0, int(sec))
    return f"{sec//3600:02d}:{sec%3600//60:02d}:{sec%60:02d}"


def reltime():
    with LOCK:
        if STATE["played"] and STATE["played_at"]:
            return hms(time.time() - STATE["played_at"])
        if STATE["paused"]:
            return hms(STATE["paused_at"] - STATE["played_at"]) if STATE.get("paused_at") else "00:00:00"
        return "00:00:00"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/description.xml":
            body = DESCRIPTION.encode()
            ctype = "text/xml"
        else:
            body, ctype = b"", "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        soapaction = (self.headers.get("SOAPACTION") or "").strip('"')
        action = soapaction.split("#")[-1] if "#" in soapaction else ""
        with LOCK:
            if action == "SetAVTransportURI":
                STATE.update(uri_set=True, played=False, paused=False, played_at=0.0)
            elif action == "Play":
                STATE["played"] = True
                STATE["paused"] = False
                STATE["played_at"] = time.time() - STATE.get("_pos", 0.0)
            elif action == "Pause":
                if STATE["played"]:
                    STATE["paused"] = True
                    STATE["played"] = False
                    STATE["paused_at"] = time.time()
                    STATE["_pos"] = time.time() - STATE["played_at"]
            elif action == "Stop":
                STATE.update(uri_set=False, played=False, paused=False, played_at=0.0, _pos=0.0)
            if action == "GetTransportInfo":
                st = ("PLAYING" if STATE["played"]
                      else "PAUSED_PLAYBACK" if STATE["paused"]
                      else "TRANSITIONING" if STATE["uri_set"] else "STOPPED")
                inner = (f"<CurrentTransportState>{st}</CurrentTransportState>"
                         f"<CurrentTransportStatus>OK</CurrentTransportStatus>")
            elif action == "GetPositionInfo":
                inner = (f"<Track>1</Track><TrackDuration>{hms(DURATION_SEC)}</TrackDuration>"
                         f"<RelTime>{reltime()}</RelTime>")
            else:
                inner = ""
        out = soap(action, inner)
        self.send_response(200)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def local_ip_for(peer):
    """请求方视角的本机 IP（单播/组播回复的 LOCATION 都用它）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((peer, 9))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def ssdp_responder(allow_multicast: bool = True):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", SSDP_PORT))  # 0.0.0.0：收单播 M-SEARCH；加成员资格后兼收组播
    if allow_multicast:
        # macOS 虚拟网卡上 IGMP join 可能阻塞数十秒（实测 CI ~75s）且 setsockopt 不释放
        # GIL 会拖住整个进程——CI 用 --no-multicast 跳过；Linux 实网用默认开启。
        # 失败不影响单播发现。
        try:
            mreq = struct.pack("4sL", socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            print("[mock] multicast membership joined", flush=True)
        except OSError as e:
            print(f"[mock] 组播加入失败（单播发现不受影响）: {e}", flush=True)
    else:
        print("[mock] multicast disabled (--no-multicast); unicast only", flush=True)
    print(f"[mock] SSDP responder on 0.0.0.0:{SSDP_PORT}", flush=True)
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except OSError:
            continue
        text = data.decode("utf-8", "replace")
        if not text.startswith("M-SEARCH"):
            continue
        st = next((line.split(":", 1)[1].strip() for line in text.split("\r\n")
                   if line.upper().startswith("ST:")), "")
        if st not in ("urn:schemas-upnp-org:service:AVTransport:1",
                      "urn:schemas-upnp-org:device:MediaRenderer:1", "ssdp:all"):
            continue
        ip = local_ip_for(addr[0])
        resp = ("HTTP/1.1 200 OK\r\n"
                f"LOCATION: http://{ip}:{HTTP_PORT}/description.xml\r\n"
                f"ST: {st}\r\n"
                f"USN: uuid:streamflow-mock-tv-1::{st}\r\n"
                "CACHE-CONTROL: max-age=1800\r\n\r\n").encode()
        for delay in (0, 0.15):  # M-SEARCH 可能丢包：补发一次
            if delay:
                time.sleep(delay)
            try:
                sock.sendto(resp, addr)
                print(f"[mock] SSDP reply to {addr[0]} via {ip} ST={st}", flush=True)
            except OSError as e:
                print(f"[mock] sendto {addr} 失败: {e}", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=HTTP_PORT)
    ap.add_argument("--no-multicast", action="store_true",
                    help="跳过 IGMP 组播加入（CI macOS 虚拟网卡 join 阻塞 ~75s；单播不受影响）")
    args = ap.parse_args()
    print(f"[mock] HTTP description at http://127.0.0.1:{args.port}/description.xml", flush=True)
    threading.Thread(target=ssdp_responder, args=(not args.no_multicast,), daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
