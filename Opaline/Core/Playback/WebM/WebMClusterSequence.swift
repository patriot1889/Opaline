import Foundation

/// Demuxes a cue-bounded range, including non-keyframe Clusters without their
/// own cue. Known-sized trailing index/tag elements are skipped, not decoded.
enum WebMClusterSequence {
    private static let levelOneIDs: Set<UInt64> = [
        0x1F43_B675, 0x1C53_BB6B, 0x1254_C367, 0x114D_9B74,
        0x1549_A966, 0x1654_AE6B, 0x1043_A770, 0x1941_A469
    ]
    private static let skippableIDs: Set<UInt64> = [
        0xEC, 0xBF, 0x1C53_BB6B, 0x1254_C367, 0x114D_9B74
    ]

    static func parse(_ data: Data, initialization: WebMInitialization) throws -> [WebMPacket] {
        var reader = try EBMLReader(data)
        var packets: [WebMPacket] = []
        var clusters = 0
        while !reader.isAtEnd {
            let start = reader.position
            let header = try reader.header()
            if header.id == 0x1F43_B675 {
                try skipCluster(after: header, reader: &reader)
                let element = EBMLReader.Element(id: header.id, payload: start..<reader.position)
                let clusterPackets = try WebMCluster.parse(
                    reader.bytes(element), initialization: initialization
                )
                packets += clusterPackets
                clusters += 1
            } else {
                guard clusters > 0, skippableIDs.contains(header.id) else {
                    throw WebMError.unsupported("non-Cluster media range or changed track metadata")
                }
                _ = try reader.element(after: header)
            }
        }
        guard clusters > 0, !packets.isEmpty else { throw WebMError.invalidElement }
        return packets
    }

    private static func skipCluster(
        after header: EBMLReader.Header, reader: inout EBMLReader
    ) throws {
        if header.size != nil {
            _ = try reader.element(after: header)
            return
        }
        // For an unknown-sized Cluster, parse child boundaries instead of
        // searching compressed bytes for a Cluster-like byte pattern.
        while !reader.isAtEnd {
            var probe = reader
            let child = try probe.header()
            if levelOneIDs.contains(child.id) {
                return
            }
            _ = try probe.element(after: child)
            reader = probe
        }
    }
}
