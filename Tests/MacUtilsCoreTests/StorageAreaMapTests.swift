import MacUtilsCore
import Testing

@Test
func storageMapPartitionsRectangleWithoutOverlapAndConservesWeightedArea() throws {
    let items = (1...41).map { StorageMapItem(id: $0, bytes: UInt64($0 * $0)) }
    let tiles = StorageAreaMap.layout(items: items, width: 900, height: 540)
    #expect(tiles.count == items.count)
    let total = items.reduce(0.0) { $0 + Double($1.bytes) }
    let area = 900.0 * 540.0
    #expect(abs(tiles.reduce(0.0) { $0 + $1.width * $1.height } - area) < area * 1e-12)
    for tile in tiles {
        let item = try #require(items.first { $0.id == tile.id })
        #expect(tile.x >= 0 && tile.y >= 0 && tile.width > 0 && tile.height > 0)
        #expect(tile.x + tile.width <= 900 + 1e-9)
        #expect(tile.y + tile.height <= 540 + 1e-9)
        #expect(abs(tile.width * tile.height / area - Double(item.bytes) / total) < 1e-12)
    }
    for first in tiles.indices {
        for second in tiles.indices where second > first {
            let a = tiles[first], b = tiles[second]
            let overlapWidth = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
            let overlapHeight = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
            #expect(overlapWidth <= 1e-9 || overlapHeight <= 1e-9)
        }
    }
}

@Test
func storageMapOmitsZerosAndRejectsEmptyOrInvalidCanvas() {
    let items = [StorageMapItem(id: 1, bytes: 0), StorageMapItem(id: 2, bytes: 4)]
    #expect(StorageAreaMap.layout(items: items) == [StorageMapTile(id: 2, x: 0, y: 0, width: 1, height: 1)])
    #expect(StorageAreaMap.layout(items: []).isEmpty)
    #expect(StorageAreaMap.layout(items: [items[0]]).isEmpty)
    for dimension in [0.0, -1, Double.infinity, Double.nan] {
        #expect(StorageAreaMap.layout(items: items, width: dimension).isEmpty)
        #expect(StorageAreaMap.layout(items: items, height: dimension).isEmpty)
    }
}

@Test
func storageMapHandlesOverflowingTotalsAndRetainsOneByteArea() throws {
    let items = [StorageMapItem(id: 1, bytes: .max), StorageMapItem(id: 2, bytes: .max),
                 StorageMapItem(id: 3, bytes: 1)]
    let tiles = StorageAreaMap.layout(items: items)
    #expect(tiles.count == 3)
    let first = try #require(tiles.first { $0.id == 1 })
    let second = try #require(tiles.first { $0.id == 2 })
    let tiny = try #require(tiles.first { $0.id == 3 })
    #expect(abs(first.width * first.height - 0.5) < 1e-12)
    #expect(abs(second.width * second.height - 0.5) < 1e-12)
    #expect(tiny.width > 0 && tiny.height > 0)
    #expect(abs(tiny.width * tiny.height / (1 / (2 * Double(UInt64.max))) - 1) < 1e-12)
}

@Test
func storageMapIsDeterministicAndAdaptsSplitToCanvasOrientation() {
    let items = [StorageMapItem(id: 9, bytes: 10), StorageMapItem(id: 2, bytes: 10)]
    let wide = StorageAreaMap.layout(items: items, width: 800, height: 200)
    #expect(wide == StorageAreaMap.layout(items: Array(items.reversed()), width: 800, height: 200))
    #expect(wide.map(\.id) == [2, 9])
    #expect(wide.map(\.width) == [400, 400])
    #expect(wide.map(\.height) == [200, 200])
    let tall = StorageAreaMap.layout(items: items, width: 200, height: 800)
    #expect(tall.map(\.width) == [200, 200])
    #expect(tall.map(\.height) == [400, 400])
}

@Test
func storageMapDrillDownUsesOnlySuppliedChildrenAndKeepsTheirSelectionIDs() {
    let overview = StorageAreaMap.layout(items: [StorageMapItem(id: 1, bytes: 100), StorageMapItem(id: 2, bytes: 300)])
    let children = StorageAreaMap.layout(items: [StorageMapItem(id: 11, bytes: 25), StorageMapItem(id: 12, bytes: 75)])
    #expect(Set(overview.map(\.id)) == [1, 2])
    #expect(Set(children.map(\.id)) == [11, 12])
    #expect(children.first?.id == 12)
    #expect(children.first.map { $0.width * $0.height } == 0.75)
    #expect(children.reduce(0.0) { $0 + $1.width * $1.height } == 1)
}
