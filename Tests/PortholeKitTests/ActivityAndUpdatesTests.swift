import Foundation
import Testing
@testable import PortholeKit

@Suite("Image updates, network and disk activity")
struct ActivityAndUpdatesTests {
    @Test("Unraid's update file: only \"false\" is an update")
    func updates() throws {
        let output = """
        @host Tower
        @updated 1794891628
        @updates {"library/nginx:alpine":{"local":"sha256:a","remote":"sha256:b","status":"false"},"louislam/uptime-kuma:2":{"local":"sha256:c","remote":"sha256:c","status":"true"},"ziggyds/iventoy:latest":{"local":null,"remote":null,"status":"undef"},"lscr.io/linuxserver/syncthing:latest":{"local":"x","remote":"y","status":"false"}}
        """
        let updates = try #require(HostInfo.parse(output).updates)
        #expect(updates.available.count == 2)
        #expect(updates.checked == Date(timeIntervalSince1970: 1_794_891_628))
        #expect(updates.hasUpdate("nginx:alpine"))
        #expect(updates.hasUpdate("lscr.io/linuxserver/syncthing"))
        #expect(!updates.hasUpdate("louislam/uptime-kuma:2"))
        #expect(!updates.hasUpdate("ziggyds/iventoy"))
    }

    @Test("Image names match Unraid's")
    func names() {
        #expect(ImageUpdates.normalized("nginx") == "library/nginx:latest")
        #expect(ImageUpdates.normalized("docker.io/amir20/dozzle") == "amir20/dozzle:latest")
        #expect(ImageUpdates.normalized("ghcr.io/sillytavern/sillytavern:staging") == "ghcr.io/sillytavern/sillytavern:staging")
        #expect(ImageUpdates.normalized("localhost:5000/app") == "localhost:5000/app:latest")
    }

    @Test("No file: no updates, and no error")
    func noFile() {
        #expect(HostInfo.parse("@host Tower\n@cores 4").updates == nil)
    }

    @Test("Network and disk activity per second, I/O wait in percent")
    func activity() {
        var load = HostLoad()
        for line in ["@cpu cpu 100 0 100 700 100 0 0 0", "@up 1000.00", "@net 1000 500", "@io 100 200", "@end",
                     "@cpu cpu 150 0 150 800 200 0 0 0", "@up 1002.00", "@net 5000 2500", "@io 2148 200", "@end"] {
            load.read(line)
        }
        #expect(load.networkIn == [2000])
        #expect(load.networkOut == [1000])
        #expect(load.network == [3000])
        #expect(load.diskRead == [524_288])
        #expect(load.diskWrite == [0])
        // 100 of 300 ticks waited on the disks.
        #expect(abs((load.ioWait.last ?? 0) - 100.0 / 3) < 0.01)
        // Waiting is not busy.
        #expect(abs((load.cpu.last ?? 0) - 100.0 / 3) < 0.01)
    }

    @Test("Counters that go back (a card reset) start over")
    func reset() {
        var load = HostLoad()
        for line in ["@up 10", "@net 9000 9000", "@up 12", "@net 10 10", "@up 14", "@net 410 210"] { load.read(line) }
        #expect(load.networkIn == [200])
        #expect(load.networkOut == [100])
    }
}
