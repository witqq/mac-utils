import Darwin
import Foundation
import MacUtilsSystem
import Testing

@Test
func systemModuleCanUseCoreDomain() {
    #expect(SystemEnvironment.productName == "Mac Utils")
}

@Test
func systemAccountHomeMatchesTheNativeUserRecord() throws {
    let entry = try #require(getpwuid(getuid()))
    let directory = try #require(entry.pointee.pw_dir)
    let expected = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        .standardizedFileURL
    let actual = try #require(SystemEnvironment.userHomeDirectoryURL)
    #expect(actual == expected)
    #expect(actual.isFileURL)
}
