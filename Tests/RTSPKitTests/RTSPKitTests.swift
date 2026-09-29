import Testing
import Foundation
@testable import RTSPKit

@Suite struct RTSPKitTests {
    @Test func parsesDigestChallenge() throws {
        let c = try #require(AuthChallenge.parse(#"Digest realm="vigi", nonce="a25fccb0", stale="FALSE""#))
        #expect(c.scheme == .digest)
        #expect(c.realm == "vigi")
        #expect(c.nonce == "a25fccb0")
        #expect(c.algorithm == "MD5")
    }

    @Test func prefersDigestOverBasic() {
        let a = Authenticator(username: "u", password: "p")
        a.update(withHeaders: [#"Basic realm="TP-LINK IP-Camera""#, #"Digest realm="TP-LINK IP-Camera", nonce="n1""#])
        #expect(a.authorization(method: "DESCRIBE", uri: "rtsp://h/stream1")?.hasPrefix("Digest ") == true)
    }

    @Test func digestMatchesRFC2617Example() {
        // RFC 2617 §3.5 example (qop=auth).
        let c = AuthChallenge(scheme: .digest, params: ["realm": "testrealm@host.com", "nonce": "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                                          "qop": "auth,auth-int", "opaque": "5ccc069c403ebaf9f0171e9517f40e41"])
        let h = Authenticator.digestHeader(challenge: c, username: "Mufasa", password: "Circle Of Life", method: "GET",
                                           uri: "/dir/index.html", nc: 1, cnonce: "0a4f113b")
        #expect(h.contains(#"response="6629fae49393a05397450978507c4ef1""#))
    }

    @Test func parsesSDP() {
        let sdp = """
        v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\na=fmtp:96 sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ;sprop-sps=QgEBAWAAAAMAAAMAAAMAAAMAlqADwIAQ5Za5JMiuAgAAAwACAAADADIQ;sprop-pps=RAHgdrAmQA==\r\na=control:trackID=1\r\nm=audio 0 RTP/AVP 8\r\na=control:trackID=2\r\n
        """
        let s = SDPSession.parse(sdp)
        #expect(s.media.count == 2)
        #expect(s.media[0].map(for: 96)?.encoding == "H265")
        #expect(s.media[1].map(for: 8)?.encoding == "PCMA")
        let ps = VideoDepacketizer.parameterSets(codec: .h265, fmtp: s.media[0].fmtp[96] ?? [:])
        #expect(ps.isComplete(for: .h265))
    }

    func rtp(seq: UInt16, ts: UInt32, marker: Bool, payload: [UInt8]) -> RTPPacket {
        RTPPacket(payloadType: 96, marker: marker, sequence: seq, timestamp: ts, ssrc: 1, payload: Data(payload), onvifTime: nil)
    }

    @Test func reassemblesH264FUA() {
        let d = VideoDepacketizer(codec: .h264)
        // IDR (type 5) split in two FU-A fragments.
        var out = d.push(rtp(seq: 1, ts: 100, marker: false, payload: [0x7C, 0x85, 0xAA, 0xBB]))
        #expect(out.isEmpty)
        out = d.push(rtp(seq: 2, ts: 100, marker: true, payload: [0x7C, 0x45, 0xCC]))
        #expect(out.count == 1)
        #expect(out[0].isKeyframe)
        #expect(out[0].nalus.first == Data([0x65, 0xAA, 0xBB, 0xCC]))
    }

    @Test func unwrapsTimestamps() {
        var u = RTPTimestampUnwrapper()
        #expect(u.unwrap(0xFFFF_FF00) == 0xFFFF_FF00)
        #expect(u.unwrap(0x0000_0100) == 0x1_0000_0100)
    }
}
