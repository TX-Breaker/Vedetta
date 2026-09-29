import Testing
import Foundation
import Security
@testable import VigiKit

@Suite struct VigiCryptoTests {
    /// Wraps a PKCS#1 RSAPublicKey in a SubjectPublicKeyInfo, like the key the NVR sends.
    func spki(fromPKCS1 pkcs1: Data) -> Data {
        func len(_ n: Int) -> [UInt8] {
            if n < 128 { return [UInt8(n)] }
            var bytes: [UInt8] = []; var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        let algo: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bit: [UInt8] = [0x03] + len(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let body = algo + bit
        return Data([0x30] + len(body.count) + body)
    }

    @Test(arguments: [1024, 2048])
    func rsaRoundTrip(bits: Int) throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        var error: Unmanaged<CFError>?
        let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &error))
        let pub = try #require(SecKeyCopyPublicKey(priv))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &error) as Data?)
        let spkiB64 = spki(fromPKCS1: pkcs1).base64EncodedString()
        // The NVR URL-encodes the key; the client must decode it first.
        let urlEncoded = spkiB64.replacingOccurrences(of: "/", with: "%2f").replacingOccurrences(of: "+", with: "%2b")
        let plain = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF:nonce123"
        let cipher = try VigiClient.rsaEncrypt(plain, publicKeyBase64: urlEncoded.removingPercentEncoding!)
        let raw = try #require(Data(base64Encoded: cipher))
        #expect(raw.count == bits / 8)
        let decrypted = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, raw as CFData, &error) as Data?)
        #expect(String(decoding: decrypted, as: UTF8.self) == plain)
    }

    @Test func uriComponentMatchesJavaScript() {
        #expect(VigiClient.encodeURIComponent("a+b/c=d") == "a%2Bb%2Fc%3Dd")
        #expect(VigiClient.encodeURIComponent("admin") == "admin")
        #expect(VigiClient.encodeURIComponent("é !") == "%C3%A9%20!")
    }

    @Test func dayString() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let d = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        #expect(VigiClient.dayString(d, calendar: cal) == "20260921")
    }
}
