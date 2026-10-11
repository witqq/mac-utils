import Foundation
import MacUtilsCore
@testable import MacUtilsApp
import Testing

@Test
func storageProgressDoesNotTreatAnUnknownOrExceededObjectEstimateAsCompletion() {
    let start = Date(timeIntervalSince1970: 100)
    let now = start.addingTimeInterval(10)
    let traversal = StorageScanProgress(visitedItems: 300, currentPath: "folder", logicalBytes: 1,
        allocatedBytes: 1, estimatedTotalItems: 100)
    let ordinary = StorageProgressStatus(progress: traversal, startedAt: start, now: now)
    #expect(ordinary.approximateFraction == nil)
    #expect(ordinary.elapsedSeconds == 10 && ordinary.averageItemsPerSecond == 30)
    let catalog = StorageScanProgress(visitedItems: 300, currentPath: "disk", logicalBytes: 1,
        allocatedBytes: 1, phase: .volumeCatalog, estimatedTotalItems: 100)
    #expect(StorageProgressStatus(progress: catalog, startedAt: start, now: now).approximateFraction == 0.99)
    let validating = StorageScanProgress(visitedItems: 300, currentPath: "disk", logicalBytes: 1,
        allocatedBytes: 1, phase: .validatingResults, estimatedTotalItems: 100)
    #expect(StorageProgressStatus(progress: validating, startedAt: start, now: now).approximateFraction == nil)
    let unavailable = StorageScanProgress(visitedItems: 300, currentPath: "disk", logicalBytes: 1,
        allocatedBytes: 1, phase: .volumeCatalog, estimatedTotalItems: 0)
    #expect(StorageProgressStatus(progress: unavailable, startedAt: start, now: now).approximateFraction == nil)
    let justStarted = StorageProgressStatus(progress: nil, startedAt: now, now: now)
    #expect(justStarted.elapsedSeconds == 0 && justStarted.averageItemsPerSecond == nil)
}

@Test
func storageInformationCaptureHooksRequireAnExplicitFixtureAndCaptureDestination() {
    for (flag, sheet) in [("--storage-show-management", StorageInformationSheet.management),
                           ("--storage-show-access", StorageInformationSheet.access)] {
        let arguments = ["Mac Utils", flag, "--screenshot-fixture", "--capture-ui", "/tmp/information.png"]
        let options = AppLaunchOptions(arguments: arguments)
        #expect(options.storageInformationSheet == sheet && options.opensSettings)
        #expect(options.storageRootURL == nil && !options.refreshesStorage && !options.showsStorageTrashConfirmation)
        #expect(AppLaunchOptions(arguments: arguments.filter { $0 != "--screenshot-fixture" })
            .storageInformationSheet == nil)
        #expect(AppLaunchOptions(arguments: ["Mac Utils", flag, "--screenshot-fixture"])
            .storageInformationSheet == nil)
    }
}
