/// One direct child of the directory being displayed. IDs must be unique within a layout.
public struct StorageMapItem: Hashable, Sendable {
    public let id: Int
    public let bytes: UInt64

    public init(id: Int, bytes: UInt64) {
        self.id = id
        self.bytes = bytes
    }
}

public struct StorageMapTile: Identifiable, Hashable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(id: Int, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A balanced treemap with no presentation or filesystem dependency.
///
/// Positive items partition the requested rectangle proportionally to bytes, within floating-point
/// precision. Zero-byte items have no area. Output is largest first, with ID as the tie-breaker,
/// independent of input order. The caller can lay out a new set of direct children for drill-down.
public enum StorageAreaMap {
    public static func layout(
        items: [StorageMapItem], width: Double = 1, height: Double = 1
    ) -> [StorageMapTile] {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return [] }
        let items = items.filter { $0.bytes > 0 }.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        guard !items.isEmpty else { return [] }
        var pending = [Region(range: items.indices, x: 0, y: 0, width: width, height: height)]
        var result: [StorageMapTile] = []
        result.reserveCapacity(items.count)
        while let region = pending.popLast() {
            if region.range.count == 1 {
                result.append(StorageMapTile(id: items[region.range.lowerBound].id,
                    x: region.x, y: region.y, width: region.width, height: region.height))
                continue
            }
            // Convert before summing: the total may legitimately exceed UInt64.max.
            let total = region.range.reduce(0.0) { $0 + Double(items[$1].bytes) }
            var prefix = 0.0
            var split = region.range.lowerBound + 1
            var closest = Double.infinity
            for index in region.range.dropLast() {
                prefix += Double(items[index].bytes)
                let distance = abs(prefix - total / 2)
                if distance < closest {
                    closest = distance
                    split = index + 1
                } else { break }
            }
            let first = region.range.lowerBound..<split
            let second = split..<region.range.upperBound
            // Sum both groups separately. Subtracting a large prefix from a rounded total would
            // erase a small positive group (for example UInt64.max alongside one byte).
            let firstWeight = first.reduce(0.0) { $0 + Double(items[$1].bytes) }
            let secondWeight = second.reduce(0.0) { $0 + Double(items[$1].bytes) }
            let combined = firstWeight + secondWeight
            let firstFraction = firstWeight / combined
            let secondFraction = secondWeight / combined
            if region.width >= region.height {
                let firstWidth = region.width * firstFraction
                pending.append(Region(range: second, x: region.x + firstWidth, y: region.y,
                    width: region.width * secondFraction, height: region.height))
                pending.append(Region(range: first, x: region.x, y: region.y,
                    width: firstWidth, height: region.height))
            } else {
                let firstHeight = region.height * firstFraction
                pending.append(Region(range: second, x: region.x, y: region.y + firstHeight,
                    width: region.width, height: region.height * secondFraction))
                pending.append(Region(range: first, x: region.x, y: region.y,
                    width: region.width, height: firstHeight))
            }
        }
        return result
    }

    private struct Region {
        let range: Range<Int>
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}
