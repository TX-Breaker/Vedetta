#!/usr/bin/env python3
"""Mock ONVIF NVR (Profile S + G) for local tests — "any brand" recorder with 2 channels.

Checks WS-UsernameToken PasswordDigest, answers Device/Media/Search/Replay calls and points
stream/replay URIs at the mediamtx test bench (scripts/test-rtsp-server.sh).
Usage: python3 mock_onvif.py <port> <credentials-file>
"""
import base64, hashlib, re, sys, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
CRED = dict(line.strip().split("=", 1) for line in open(sys.argv[2]) if "=" in line)
USER, PASS = CRED["USER"], CRED["PASS"]
RTSP = "rtsp://127.0.0.1:8554"
import os
CHANNELS = int(os.environ.get("MOCK_CHANNELS", "2"))
def path_for(ch):  # the test bench publishes channels 1 and 2 only: reuse them
    return (ch - 1) % 2 + 1
BASE = "http://127.0.0.1:%d/onvif" % PORT

def env(body):
    return ('<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
            'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tse="http://www.onvif.org/ver10/search/wsdl" '
            'xmlns:trp="http://www.onvif.org/ver10/replay/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" '
            'xmlns:tns1="http://www.onvif.org/ver10/topics"><s:Body>%s</s:Body></s:Envelope>' % body)

def fault(reason, sub="ter:NotAuthorized"):
    return env('<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>%s</s:Value></s:Subcode></s:Code>'
               '<s:Reason><s:Text xml:lang="en">%s</s:Text></s:Reason></s:Fault>' % (sub, reason))

def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def authorized(xml):
    u = re.search(r"<(?:\w+:)?Username>([^<]*)<", xml)
    p = re.search(r"<(?:\w+:)?Password[^>]*>([^<]*)<", xml)
    n = re.search(r"<(?:\w+:)?Nonce[^>]*>([^<]*)<", xml)
    c = re.search(r"<(?:\w+:)?Created[^>]*>([^<]*)<", xml)
    if not (u and p and n and c) or u.group(1) != USER:
        return False
    digest = base64.b64encode(hashlib.sha1(base64.b64decode(n.group(1)) + c.group(1).encode() + PASS.encode()).digest()).decode()
    return digest == p.group(1)

def day_start(ts):
    d = datetime.fromtimestamp(ts).replace(hour=0, minute=0, second=0, microsecond=0)
    return d.timestamp()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, xml, code=200):
        data = xml.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/soap+xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        xml = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        op = re.search(r"<s:Body>\s*<(?:\w+:)?(\w+)", xml)
        op = op.group(1) if op else ""
        if op == "GetSystemDateAndTime":
            t = datetime.now(timezone.utc)
            return self.send(env('<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType>'
                                 '<tt:UTCDateTime><tt:Time><tt:Hour>%d</tt:Hour><tt:Minute>%d</tt:Minute><tt:Second>%d</tt:Second></tt:Time>'
                                 '<tt:Date><tt:Year>%d</tt:Year><tt:Month>%d</tt:Month><tt:Day>%d</tt:Day></tt:Date></tt:UTCDateTime>'
                                 '</tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>' % (t.hour, t.minute, t.second, t.year, t.month, t.day)))
        if not authorized(xml):
            return self.send(fault("Sender not Authorized"), 400)
        if op == "GetDeviceInformation":
            return self.send(env('<tds:GetDeviceInformationResponse><tds:Manufacturer>Hikvision</tds:Manufacturer><tds:Model>DS-7608NI-MOCK</tds:Model>'
                                 '<tds:FirmwareVersion>V4.1.0</tds:FirmwareVersion><tds:SerialNumber>MOCK123</tds:SerialNumber><tds:HardwareId>88</tds:HardwareId>'
                                 '</tds:GetDeviceInformationResponse>'))
        if op == "GetServices":
            svc = "".join('<tds:Service><tds:Namespace>%s</tds:Namespace><tds:XAddr>%s/%s</tds:XAddr><tds:Version><tt:Major>2</tt:Major><tt:Minor>0</tt:Minor></tds:Version></tds:Service>' % (ns, BASE, name)
                          for ns, name in [("http://www.onvif.org/ver10/device/wsdl", "device_service"),
                                           ("http://www.onvif.org/ver10/media/wsdl", "Media"),
                                           ("http://www.onvif.org/ver10/search/wsdl", "SearchRecording"),
                                           ("http://www.onvif.org/ver10/replay/wsdl", "Replay"),
                                           ("http://www.onvif.org/ver20/ptz/wsdl", "PTZ")])
            return self.send(env('<tds:GetServicesResponse>%s</tds:GetServicesResponse>' % svc))
        if op == "GetProfiles":
            prof = ""
            for ch in range(1, CHANNELS + 1):
                for main, (w, h) in ((True, (1920, 1080)), (False, (640, 360))):
                    tok = "Profile_%d0%d" % (ch, 1 if main else 2)
                    prof += ('<trt:Profiles token="%s" fixed="true"><tt:Name>%s</tt:Name>'
                             '<tt:VideoSourceConfiguration token="VSC%d"><tt:Name>VSC</tt:Name><tt:UseCount>2</tt:UseCount><tt:SourceToken>VideoSource_%d</tt:SourceToken>'
                             '<tt:Bounds x="0" y="0" width="1920" height="1080"/></tt:VideoSourceConfiguration>'
                             '<tt:VideoEncoderConfiguration token="VEC%s"><tt:Name>VEC</tt:Name><tt:UseCount>1</tt:UseCount><tt:Encoding>H264</tt:Encoding>'
                             '<tt:Resolution><tt:Width>%d</tt:Width><tt:Height>%d</tt:Height></tt:Resolution><tt:Quality>5</tt:Quality>'
                             '<tt:RateControl><tt:FrameRateLimit>25</tt:FrameRateLimit><tt:EncodingInterval>1</tt:EncodingInterval><tt:BitrateLimit>2048</tt:BitrateLimit></tt:RateControl>'
                             '</tt:VideoEncoderConfiguration>%s</trt:Profiles>') % (tok, tok, ch, ch, tok, w, h,
                             '<tt:PTZConfiguration token="PTZ1"><tt:Name>PTZ</tt:Name><tt:UseCount>1</tt:UseCount><tt:NodeToken>N1</tt:NodeToken></tt:PTZConfiguration>' if ch == 1 else '')
            return self.send(env('<trt:GetProfilesResponse>%s</trt:GetProfilesResponse>' % prof))
        if op == "GetStreamUri":
            tok = re.search(r"ProfileToken>([^<]+)<", xml).group(1)
            ch, sub = int(tok[8:-2]), tok.endswith("2")
            ch = path_for(ch)
            return self.send(env('<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>%s/live/%d/%d/avm</tt:Uri><tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>'
                                 '<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot><tt:Timeout>PT0S</tt:Timeout></trt:MediaUri></trt:GetStreamUriResponse>'
                                 % (RTSP, ch, 2 if sub else 1)))
        if op in ("ContinuousMove", "Stop", "GotoPreset", "RemovePreset", "SetPreset", "GetPresets"):
            ptz = self.server.ptz
            prof = re.search(r"ProfileToken>([^<]+)<", xml)
            if not prof or not prof.group(1).startswith("Profile_1"):
                return self.send(fault("No PTZ on this profile", "ter:NoProfile"), 400)
            ptz["log"].append(op)
            if op == "ContinuousMove":
                m = re.search(r'PanTilt[^>]*x="([-0-9.]+)"[^>]*y="([-0-9.]+)"', xml)
                z = re.search(r'Zoom[^>]*x="([-0-9.]+)"', xml)
                ptz["last"] = (m.group(1), m.group(2)) if m else ("0", "0")
                ptz["zoom"] = z.group(1) if z else "0"
                return self.send(env('<tptz:ContinuousMoveResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"/>'))
            if op == "Stop":
                return self.send(env('<tptz:StopResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"/>'))
            if op == "SetPreset":
                name = re.search(r"PresetName>([^<]*)<", xml).group(1)
                tok = "P%d" % (len(ptz["presets"]) + 1)
                ptz["presets"][tok] = name
                return self.send(env('<tptz:SetPresetResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"><tptz:PresetToken>%s</tptz:PresetToken></tptz:SetPresetResponse>' % tok))
            if op == "GetPresets":
                items = "".join('<tptz:Preset token="%s"><tt:Name>%s</tt:Name></tptz:Preset>' % (k, v) for k, v in ptz["presets"].items())
                return self.send(env('<tptz:GetPresetsResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">%s</tptz:GetPresetsResponse>' % items))
            tok = re.search(r"PresetToken>([^<]+)<", xml).group(1)
            if tok not in ptz["presets"]:
                return self.send(fault("No such preset", "ter:NoToken"), 400)
            if op == "RemovePreset":
                del ptz["presets"][tok]
            return self.send(env('<tptz:%sResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"/>' % op))
        if op == "FindRecordings":
            return self.send(env('<tse:FindRecordingsResponse><tse:SearchToken>rec-search</tse:SearchToken></tse:FindRecordingsResponse>'))
        if op == "GetRecordingSearchResults":
            now = time.time()
            recs = "".join('<tt:RecordingInformation><tt:RecordingToken>Rec_%d</tt:RecordingToken><tt:Source><tt:SourceId>VideoSource_%d</tt:SourceId>'
                           '<tt:Name>Camera %02d</tt:Name><tt:Location/><tt:Description/><tt:Address/></tt:Source>'
                           '<tt:EarliestRecording>%s</tt:EarliestRecording><tt:LatestRecording>%s</tt:LatestRecording><tt:Content/>'
                           '<tt:RecordingStatus>Recording</tt:RecordingStatus></tt:RecordingInformation>' % (ch, ch, ch, iso(now - 10 * 86400), iso(now))
                           for ch in reversed(range(1, CHANNELS + 1)))
            return self.send(env('<tse:GetRecordingSearchResultsResponse><tse:ResultList><tt:SearchState>Completed</tt:SearchState>%s</tse:ResultList>'
                                 '</tse:GetRecordingSearchResultsResponse>' % recs))
        if op == "FindEvents":
            st = re.search(r"StartPoint>([^<]+)<", xml).group(1)
            self.server.event_start = datetime.strptime(st, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
            self.server.event_rec = re.search(r"IncludedRecordings[^>]*>([^<]+)<", xml).group(1)
            return self.send(env('<tse:FindEventsResponse><tse:SearchToken>ev-search</tse:SearchToken></tse:FindEventsResponse>'))
        if op == "GetEventSearchResults":
            base = self.server.event_start
            rec = self.server.event_rec
            def result(t, topic, name, value, start=False):
                return ('<tt:Result><tt:RecordingToken>%s</tt:RecordingToken><tt:TrackToken>VIDEO001</tt:TrackToken><tt:Time>%s</tt:Time>'
                        '<tt:Event><wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">%s</wsnt:Topic>'
                        '<wsnt:Message><tt:Message UtcTime="%s"><tt:Source/><tt:Data><tt:SimpleItem Name="%s" Value="%s"/></tt:Data></tt:Message></wsnt:Message></tt:Event>'
                        '<tt:StartStateEvent>%s</tt:StartStateEvent></tt:Result>') % (rec, iso(t), topic, iso(t), name, value, "true" if start else "false")
            now = time.time()
            items = [result(base, "tns1:RecordingHistory/Track/State", "IsDataPresent", "true", True),
                     result(base + 7 * 3600, "tns1:RecordingHistory/Track/State", "IsDataPresent", "false"),
                     result(base + 7.5 * 3600, "tns1:RecordingHistory/Track/State", "IsDataPresent", "true"),
                     result(base + 9 * 3600, "tns1:VideoSource/MotionAlarm", "State", "true"),
                     result(base + 9 * 3600 + 40, "tns1:VideoSource/MotionAlarm", "State", "false"),
                     result(base + 11 * 3600, "tns1:RuleEngine/LineDetector/Crossed", "State", "true"),
                     result(base + 11 * 3600 + 5, "tns1:RuleEngine/LineDetector/Crossed", "State", "false")]
            items = [i for i in items if re.search(r"<tt:Time>([^<]+)<", i) and
                     datetime.strptime(re.search(r"<tt:Time>([^<]+)<", i).group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() <= now]
            return self.send(env('<tse:GetEventSearchResultsResponse><tse:ResultList><tt:SearchState>Completed</tt:SearchState>%s</tse:ResultList>'
                                 '</tse:GetEventSearchResultsResponse>' % "".join(items)))
        if op == "EndSearch":
            return self.send(env('<tse:EndSearchResponse><tse:Endpoint>%s</tse:Endpoint></tse:EndSearchResponse>' % iso(time.time())))
        if op == "GetReplayUri":
            tok = re.search(r"RecordingToken>([^<]+)<", xml).group(1)
            return self.send(env('<trp:GetReplayUriResponse><trp:Uri>%s/replay/%d/1/avm</trp:Uri></trp:GetReplayUriResponse>' % (RTSP, path_for(int(tok.split("_")[1])))))
        return self.send(fault("Action not supported", "ter:ActionNotSupported"), 400)

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.event_start = time.time()
    srv.event_rec = "Rec_1"
    srv.ptz = {"presets": {}, "log": [], "last": None, "zoom": "0"}
    print("mock ONVIF NVR on %s/device_service" % BASE, flush=True)
    srv.serve_forever()
