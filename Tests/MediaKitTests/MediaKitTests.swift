import Testing
import Foundation
@testable import MediaKit

@Suite struct MediaKitTests {
    @Test func g711Silence() {
        #expect(G711.decode(Data([0xFF]), alaw: false) == [0])
        #expect(abs(Int(G711.decode(Data([0xD5]), alaw: true)[0])) <= 8)
    }
}
