import Foundation
import Testing
@testable import PortholeKit

@Suite("Unraid's array and disks")
struct UnraidTests {
    /// The real server's files, 2026-11-16.
    let output = """
    @host Tower
    @var sbSynced="1794700801"
    @var sbSyncErrs="0"
    @var sbSynced2="1794721882"
    @var sbSyncExit="0"
    @var mdResyncPos="0"
    @var mdResyncDb="0"
    @var mdResyncDt="0"
    @var mdResyncAction="check P"
    @var mdResyncSize="1953514552"
    @var mdState="STARTED"
    @dsk ["parity"]
    @dsk name="parity"
    @dsk device="sda"
    @dsk rotational="1"
    @dsk spundown="0"
    @dsk status="DISK_OK"
    @dsk temp="38"
    @dsk numErrors="0"
    @dsk type="Parity"
    @dsk ["disk1"]
    @dsk name="disk1"
    @dsk device="sdb"
    @dsk rotational="1"
    @dsk spundown="1"
    @dsk status="DISK_OK"
    @dsk temp="*"
    @dsk numErrors="0"
    @dsk type="Data"
    @dsk ["parity2"]
    @dsk name="parity2"
    @dsk device=""
    @dsk rotational=""
    @dsk spundown="0"
    @dsk status="DISK_NP_DSBL"
    @dsk temp="*"
    @dsk numErrors="0"
    @dsk type="Parity"
    @dsk ["cache"]
    @dsk name="cache"
    @dsk device="nvme0n1"
    @dsk rotational="0"
    @dsk spundown="0"
    @dsk status="DISK_OK"
    @dsk temp="54"
    @dsk numErrors="0"
    @dsk type="Cache"
    @dsk ["flash"]
    @dsk name="flash"
    @dsk device="sdc"
    @dsk status="DISK_OK"
    @dsk type="Flash"
    """

    @Test("var.ini and disks.ini parse; an empty slot and the flash are not disks")
    func parse() throws {
        let array = try #require(HostInfo.parse(output).array)
        #expect(array.isStarted)
        #expect(array.disks.map(\.title) == ["Parity", "Disk 1", "Cache"])
        #expect(array.disks[0].temperature == 38)
        #expect(array.disks[1].temperature == nil && array.disks[1].spunDown)
        #expect(array.check == nil)
        #expect(array.lastCheck?.errors == 0)
        #expect(array.lastCheck?.duration == 21_081)
        // A 54 °C NVMe is normal.
        #expect(array.troubled.isEmpty)
    }

    @Test("A check under way has its progress and speed")
    func running() throws {
        let running = output.replacingOccurrences(of: #"@var mdResyncPos="0""#, with: #"@var mdResyncPos="976757276""#)
            .replacingOccurrences(of: #"@var mdResyncDb="0""#, with: #"@var mdResyncDb="1200000""#)
            .replacingOccurrences(of: #"@var mdResyncDt="0""#, with: #"@var mdResyncDt="10""#)
        let check = try #require(HostInfo.parse(running).array?.check)
        #expect(check.title == "Parity check")
        #expect(abs(check.fraction - 0.5) < 0.001)
        #expect(check.speed == 120_000 * 1024)
        #expect(check.remaining.map { Int($0) } == Int(1_953_514_552.0 * 1024 / 2 / (120_000 * 1024)))
    }

    @Test("Failing disks come before hot ones")
    func troubled() {
        let array = UnraidArray(disks: [
            .init(name: "disk2", type: "Data", temperature: 52),
            .init(name: "disk3", type: "Data", status: "DISK_DSBL"),
            .init(name: "disk4", type: "Data", temperature: 40, errors: 3),
            .init(name: "cache", type: "Cache", temperature: 60, rotational: false),
        ])
        #expect(array.troubled.map(\.name) == ["disk3", "disk4", "disk2"])
        #expect(array.troubled.map(\.problem) == ["Disabled", "3 read or write errors", "Hot: 52 °C"])
    }

    @Test("A server that isn't Unraid has no array")
    func notUnraid() {
        #expect(HostInfo.parse("@host box\n@cores 4").array == nil)
    }
}
