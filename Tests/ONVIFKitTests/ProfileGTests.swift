import Testing
import Foundation
@testable import ONVIFKit

@Suite struct ProfileGTests {
    func ev(_ t: Double, _ topic: String, _ items: [String: String]) -> ONVIFRecordingEvent {
        ONVIFRecordingEvent(recordingToken: "R", time: Date(timeIntervalSince1970: t), topic: topic, items: items, isStartState: false)
    }

    @Test func dataIntervalsFollowTransitions() {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let end = day.addingTimeInterval(86400)
        let events = [ev(1_000_000, "tns1:RecordingHistory/Track/State", ["IsDataPresent": "true"]),
                      ev(1_000_000 + 3600, "tns1:RecordingHistory/Track/State", ["IsDataPresent": "false"]),
                      ev(1_000_000 + 5400, "tns1:VideoSource/MotionAlarm", ["State": "true"]),
                      ev(1_000_000 + 7200, "tns1:RecordingHistory/Track/State", ["IsDataPresent": "true"]),
                      ev(1_000_000 + 9000, "tns1:RecordingHistory/Track/State", ["IsDataPresent": "false"])]
        let iv = ONVIFClient.dataIntervals(from: events, dayStart: day, dayEnd: end)
        #expect(iv.count == 2)
        #expect(iv[0].duration == 3600)
        #expect(iv[1].start == day.addingTimeInterval(7200))
    }

    @Test func noHistoryMeansNoIntervals() {
        let day = Date(timeIntervalSince1970: 0)
        #expect(ONVIFClient.dataIntervals(from: [ev(10, "tns1:VideoSource/MotionAlarm", ["State": "true"])],
                                          dayStart: day, dayEnd: day.addingTimeInterval(86400)).isEmpty)
    }

    @Test func topicsMapToEventCodes() {
        #expect(ONVIFClient.eventCode(forTopic: "tns1:VideoSource/MotionAlarm", items: [:]) == 1)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:RuleEngine/CellMotionDetector/Motion", items: [:]) == 1)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:RuleEngine/LineDetector/Crossed", items: [:]) == 3)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:RuleEngine/FieldDetector/ObjectsInside", items: [:]) == 4)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:RuleEngine/MyRuleDetector/PeopleDetect", items: [:]) == 12)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:RuleEngine/ObjectDetection/Object", items: ["ClassTypes": "Vehicle"]) == 13)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:Device/Trigger/DigitalInput", items: [:]) == 27)
        #expect(ONVIFClient.eventCode(forTopic: "tns1:Monitoring/ProcessorUsage", items: [:]) == nil)
    }

    @Test func parsesDates() {
        #expect(ONVIFClient.parseDate("2026-09-28T10:00:00Z") == Date(timeIntervalSince1970: 1_790_589_600))
        #expect(ONVIFClient.parseDate("2026-09-28T10:00:00.250Z") != nil)
        #expect(ONVIFClient.parseDate("2026-09-28T10:00:00") == Date(timeIntervalSince1970: 1_790_589_600))
        #expect(ONVIFClient.parseDate("2026-09-28T12:00:00+02:00") == Date(timeIntervalSince1970: 1_790_589_600))
    }

    @Test func detectionState() {
        #expect(ev(0, "tns1:VideoSource/MotionAlarm", ["State": "true"]).detectionActive == true)
        #expect(ev(0, "tns1:RuleEngine/CellMotionDetector/Motion", ["IsMotion": "false"]).detectionActive == false)
        #expect(ev(0, "tns1:RecordingHistory/Track/State", ["IsDataPresent": "true"]).detectionActive == nil)
    }
}
