import Foundation
import XCTest
@testable import SOMACore

final class SOMACodexLocatorTests: XCTestCase {
    func testFindsExecutableInsideRenamedApplicationBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let executable = applications
            .appendingPathComponent("AI Chat.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: executable)

        let installation = SOMACodexLocator.locate(
            environment: [:],
            homeDirectory: root,
            applicationDirectories: [applications]
        )

        XCTAssertEqual(installation?.executableURL.path, executable.path)
        XCTAssertEqual(installation?.source, .applicationBundle)
    }

    func testEnvironmentOverrideWinsOverPathAndApplicationBundles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("custom/codex")
        let pathExecutable = root.appendingPathComponent("bin/codex")
        try makeExecutable(at: override)
        try makeExecutable(at: pathExecutable)

        let installation = SOMACodexLocator.locate(
            environment: [
                "SOMA_CODEX_BINARY": override.path,
                "PATH": pathExecutable.deletingLastPathComponent().path,
            ],
            homeDirectory: root,
            applicationDirectories: []
        )

        XCTAssertEqual(installation?.executableURL.path, override.path)
        XCTAssertEqual(installation?.source, .environmentOverride)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
