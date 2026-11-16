import Foundation
import Testing
@testable import PortholeKit

@Suite("Warnings and errors per hour")
struct ProblemsByHourTests {
    // 2026-11-16 14:30 UTC.
    let now = Date(timeIntervalSince1970: 1_794_839_400)

    @Test("A line falls in its clock hour; the last is the current hour")
    func hourIndex() {
        #expect(ProblemSummary.hourIndex(of: now, now: now) == 23)
        #expect(ProblemSummary.hourIndex(of: now.addingTimeInterval(-25 * 60), now: now) == 23)   // 14:05
        #expect(ProblemSummary.hourIndex(of: now.addingTimeInterval(-35 * 60), now: now) == 22)   // 13:55
        #expect(ProblemSummary.hourIndex(of: now.addingTimeInterval(-23 * 3600), now: now) == 0)
        #expect(ProblemSummary.hourIndex(of: now.addingTimeInterval(-24 * 3600), now: now) == nil)
        #expect(ProblemSummary.hourIndex(of: now.addingTimeInterval(120), now: now) == 23)   // a clock a little ahead
        let starts = ProblemSummary.hourStarts(now: now)
        #expect(starts.count == 24)
        #expect(starts.last == Date(timeIntervalSince1970: 1_794_837_600))   // 14:00
    }

    @Test("The scan counts each line in its hour, errors and warnings apart")
    func parse() {
        let output = """
        @@@ app
        2026-11-16T09:10:00.000000000Z level=error msg="first"
        2026-11-16T09:50:00.000000000Z level=warning msg="second"
        2026-11-16T14:20:00.000000000Z level=error msg="third"
        level=error msg="no time"
        """
        let summary = ProblemSummary.parse(output, now: now)["app"]
        #expect(summary?.errors == 3)
        #expect(summary?.errorsByHour[18] == 1)   // 09:00
        #expect(summary?.warningsByHour[18] == 1)
        #expect(summary?.errorsByHour[23] == 1)   // 14:00
        #expect(summary?.errorsByHour.reduce(0, +) == 2)   // not the line without a time
    }
}
