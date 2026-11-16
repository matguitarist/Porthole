import Foundation
import Testing
@testable import PortholeKit

@Suite("Docker's disk space")
struct DockerDiskTests {
    @Test("docker system df and log sizes parse")
    func parse() {
        let output = """
        @df {"Active":"32","Reclaimable":"0B (0%)","Size":"21.71GB","TotalCount":"32","Type":"Images"}
        @df {"Active":"25","Reclaimable":"1.409MB (6%)","Size":"21.62MB","TotalCount":"36","Type":"Containers"}
        @df {"Active":"4","Reclaimable":"725MB (9%)","Size":"8.053GB","TotalCount":"13","Type":"Local Volumes"}
        @df {"Active":"0","Reclaimable":"1.543GB","Size":"8.754GB","TotalCount":"35","Type":"Build Cache"}
        @log plex 2048
        @log sonarr 90000000
        @log empty 0
        """
        let disk = DockerDisk.parse(output)
        #expect(disk.usage.map(\.kind) == [.images, .containers, .volumes, .buildCache])
        #expect(disk.usage[0].size == 21.71e9)
        #expect(disk.usage[1].reclaimable == 1.409e6)
        #expect(disk.usage[3].reclaimable == 1.543e9)
        #expect(disk.usage[2].count == 13)
        #expect(disk.biggestLogs(5).map(\.name) == ["sonarr", "plex"])
    }

    @Test("docker.img is its own disk; a directory on the cache doesn't repeat the cache")
    func dockerMount() {
        let image = HostInfo.parse("""
        @disk /mnt/cache 499862622208 345574735872 /dev/nvme0n1p1
        @disk /var/lib/docker 53687091200 39435116544 /dev/loop2
        """)
        #expect(image.disks.map(\.title) == ["Cache", "Docker"])
        let directory = HostInfo.parse("""
        @disk /mnt/cache 499862622208 345574735872 /dev/nvme0n1p1
        @disk /var/lib/docker 499862622208 345574735872 /dev/nvme0n1p1
        """)
        #expect(directory.disks.map(\.mount) == ["/mnt/cache"])
        // Older lines without the filesystem still read.
        #expect(HostInfo.parse("@disk /boot 31000000000 2700000000").disks.count == 1)
    }
}
