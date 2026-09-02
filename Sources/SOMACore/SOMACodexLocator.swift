import Foundation

/// Resolves the Codex CLI without depending on an application display name.
/// The desktop application has shipped under more than one bundle name, while
/// the embedded executable contract remains `Contents/Resources/codex`.
public enum SOMACodexLocator {
    public struct Installation: Equatable, Sendable {
        public enum Source: String, Equatable, Sendable {
            case environmentOverride
            case executablePath
            case applicationBundle
        }

        public let executableURL: URL
        public let source: Source

        public init(executableURL: URL, source: Source) {
            self.executableURL = executableURL.standardizedFileURL
            self.source = source
        }
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> Installation? {
        if let override = environment["SOMA_CODEX_BINARY"],
           let executable = executableURL(at: override, fileManager: fileManager) {
            return Installation(executableURL: executable, source: .environmentOverride)
        }

        let pathCandidates = executablePathCandidates(
            environment: environment,
            homeDirectory: homeDirectory
        )
        for candidate in pathCandidates {
            if let executable = executableURL(at: candidate.path, fileManager: fileManager) {
                return Installation(executableURL: executable, source: .executablePath)
            }
        }

        let roots = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in roots {
            for bundleURL in applicationBundles(in: root, fileManager: fileManager) {
                for relativePath in ["Contents/Resources/codex", "Contents/MacOS/codex"] {
                    let candidate = bundleURL.appendingPathComponent(relativePath)
                    if let executable = executableURL(at: candidate.path, fileManager: fileManager) {
                        return Installation(executableURL: executable, source: .applicationBundle)
                    }
                }
            }
        }
        return nil
    }

    private static func executablePathCandidates(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
            })
        }
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        return unique(candidates)
    }

    private static func applicationBundles(in root: URL, fileManager: FileManager) -> [URL] {
        let preferred = ["Codex.app", "ChatGPT.app"].map { root.appendingPathComponent($0) }
        let discovered = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame } ?? []
        return unique(preferred + discovered.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private static func executableURL(at path: String, fileManager: FileManager) -> URL? {
        guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
