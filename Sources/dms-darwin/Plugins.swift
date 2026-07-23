import CryptoKit
import Foundation

// The `plugins.*` channel: a faithful port of the upstream Go daemon's
// plugin registry/manager (core/internal/plugins + server/plugins).
// The registry is a git clone of the public dms-plugin-registry cached in
// the temp dir; installs clone into the shell's plugins directory (shared
// repos deduplicated under .repos with a symlink + .meta, exactly like
// upstream). Response shapes and error texts mirror the Go handlers.
final class PluginsChannel {
    struct Plugin {
        var id = ""
        var name = ""
        var category = ""
        var author = ""
        var description = ""
        var repo = ""
        var path = ""
        var screenshot = ""
        var capabilities: [String] = []
        var compositors: [String] = []
        var dependencies: [String] = []
        var requiresDMS = ""
        var featured = false
    }

    private let registryRepo = "https://github.com/AvengeMedia/dms-plugin-registry.git"
    private let feedbackURL = "https://api.danklinux.com/plugins"
    private let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dankdots-plugin-registry", isDirectory: true)
    private let pluginsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/DankMaterialShell/plugins", isDirectory: true)
    private var plugins: [Plugin] = []

    // ---- git (system git via Process, the CLT is a project prerequisite) ----

    private func git(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func cloneOrPull(url: String, into dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            if self.git(["-C", dir.path, "pull", "--ff-only"]) { return true }
            // Corrupted or diverged: upstream deletes and re-clones.
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(
            at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        return self.git(["clone", "--depth", "1", url, dir.path])
    }

    // ---- registry ----

    private func updateRegistry() -> String? {
        guard self.cloneOrPull(url: self.registryRepo, into: self.cacheDir) else {
            return "failed to clone registry"
        }
        let dir = self.cacheDir.appendingPathComponent("plugins")
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else {
            return "failed to read plugins directory"
        }
        self.plugins = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var plugin = Plugin()
            plugin.id = object["id"] as? String ?? entry.deletingPathExtension().lastPathComponent
            plugin.name = object["name"] as? String ?? ""
            plugin.category = object["category"] as? String ?? ""
            plugin.author = object["author"] as? String ?? ""
            plugin.description = object["description"] as? String ?? ""
            plugin.repo = object["repo"] as? String ?? ""
            plugin.path = object["path"] as? String ?? ""
            plugin.screenshot = object["screenshot"] as? String ?? ""
            plugin.capabilities = object["capabilities"] as? [String] ?? []
            plugin.compositors = object["compositors"] as? [String] ?? []
            plugin.dependencies = object["dependencies"] as? [String] ?? []
            plugin.requiresDMS = object["requires_dms"] as? String ?? ""
            plugin.featured = object["featured"] as? Bool ?? false
            self.plugins.append(plugin)
        }
        return nil
    }

    private func registryList() -> (plugins: [Plugin], error: String?) {
        if self.plugins.isEmpty, let failure = self.updateRegistry() {
            return ([], failure)
        }
        // Upstream's stable first-party-first ordering.
        let sorted = self.plugins.enumerated().sorted { a, b in
            let firstA = a.element.repo.hasPrefix("https://github.com/AvengeMedia")
            let firstB = b.element.repo.hasPrefix("https://github.com/AvengeMedia")
            if firstA != firstB { return firstA }
            return a.offset < b.offset
        }.map(\.element)
        return (sorted, nil)
    }

    // Upstream's fuzzyMatch: query characters appearing in order in text.
    private static func fuzzyMatch(_ query: String, _ text: String) -> Bool {
        var index = query.startIndex
        for character in text {
            if index < query.endIndex && character == query[index] {
                index = query.index(after: index)
            }
        }
        return index == query.endIndex
    }

    // ---- feedback (best-effort, like upstream's FetchFeedback) ----

    private func fetchFeedback() -> [String: [String: Any]] {
        guard let url = URL(string: self.feedbackURL) else { return [:] }
        var result: [String: [String: Any]] = [:]
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let list = object["plugins"] as? [[String: Any]]
            else { return }
            for entry in list {
                guard let id = entry["id"] as? String else { continue }
                result[id] = entry
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    // ---- manager ----

    private func repoName(for repoURL: String) -> String {
        let digest = SHA256.hash(data: Data(repoURL.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func manifestID(at path: String) -> String? {
        let manifest = URL(fileURLWithPath: path).appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["id"] as? String
    }

    private func installedPath(for pluginID: String) -> String? {
        guard !pluginID.isEmpty, pluginID != ".", pluginID != "..",
            !pluginID.contains("/"), !pluginID.contains("\\")
        else { return nil }
        let fm = FileManager.default
        let exact = self.pluginsDir.appendingPathComponent(pluginID).path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: exact, isDirectory: &isDir), isDir.boolValue { return exact }
        guard let entries = try? fm.contentsOfDirectory(atPath: self.pluginsDir.path) else {
            return nil
        }
        for name in entries where name != ".repos" && !name.hasSuffix(".meta") {
            let full = self.pluginsDir.appendingPathComponent(name).path
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue,
                self.manifestID(at: full) == pluginID
            {
                return full
            }
        }
        return nil
    }

    private func listInstalledIDs() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: self.pluginsDir.path) else {
            return []
        }
        var ids: [String] = []
        for name in entries.sorted() where name != ".repos" && !name.hasSuffix(".meta") {
            let full = self.pluginsDir.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            ids.append(self.manifestID(at: full) ?? name)
        }
        return ids
    }

    private func install(_ plugin: Plugin) -> String? {
        let fm = FileManager.default
        let pluginPath = self.pluginsDir.appendingPathComponent(plugin.id)
        if fm.fileExists(atPath: pluginPath.path) {
            return "plugin already installed: \(plugin.name)"
        }
        try? fm.createDirectory(at: self.pluginsDir, withIntermediateDirectories: true)

        if !plugin.path.isEmpty {
            // Shared repository: clone once under .repos, symlink the subpath.
            let reposDir = self.pluginsDir.appendingPathComponent(".repos")
            let repoPath = reposDir.appendingPathComponent(self.repoName(for: plugin.repo))
            guard self.cloneOrPull(url: plugin.repo, into: repoPath) else {
                return "failed to clone repository"
            }
            let source = repoPath.appendingPathComponent(plugin.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                return "plugin path does not exist in repository: \(plugin.path)"
            }
            do {
                try fm.createSymbolicLink(at: pluginPath, withDestinationURL: source)
            } catch {
                return "failed to create symlink: \(error.localizedDescription)"
            }
            let meta = "repo=\(plugin.repo)\npath=\(plugin.path)\nrepodir=\(self.repoName(for: plugin.repo))"
            try? meta.write(
                toFile: pluginPath.path + ".meta", atomically: true, encoding: .utf8)
        } else {
            guard self.cloneOrPull(url: plugin.repo, into: pluginPath) else {
                try? fm.removeItem(at: pluginPath)
                return "failed to clone plugin"
            }
        }
        return nil
    }

    private func uninstall(_ plugin: Plugin) -> String? {
        let fm = FileManager.default
        guard let path = self.installedPath(for: plugin.id) else {
            return "plugin not installed: \(plugin.name)"
        }
        let metaPath = path + ".meta"
        if fm.fileExists(atPath: metaPath) {
            // Symlinked subpath install: drop link + meta, and the shared
            // repo when no other .meta still references it.
            let repoDir = self.repoName(for: plugin.repo)
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: metaPath)
            let stillReferenced = ((try? fm.contentsOfDirectory(atPath: self.pluginsDir.path))
                ?? []).contains { name in
                    guard name.hasSuffix(".meta"),
                        let contents = try? String(
                            contentsOfFile: self.pluginsDir.appendingPathComponent(name).path,
                            encoding: .utf8)
                    else { return false }
                    return contents.contains("repodir=\(repoDir)")
                }
            if !stillReferenced {
                try? fm.removeItem(
                    at: self.pluginsDir.appendingPathComponent(".repos")
                        .appendingPathComponent(repoDir))
            }
        } else {
            try? fm.removeItem(atPath: path)
        }
        return nil
    }

    private func update(_ plugin: Plugin) -> String? {
        let fm = FileManager.default
        guard let path = self.installedPath(for: plugin.id) else {
            return "plugin not installed: \(plugin.name)"
        }
        if fm.fileExists(atPath: path + ".meta") {
            let repoPath = self.pluginsDir.appendingPathComponent(".repos")
                .appendingPathComponent(self.repoName(for: plugin.repo))
            guard self.cloneOrPull(url: plugin.repo, into: repoPath) else {
                return "failed to update repository"
            }
        } else {
            guard self.cloneOrPull(url: plugin.repo, into: URL(fileURLWithPath: path)) else {
                return "failed to update plugin"
            }
        }
        return nil
    }

    // ---- wire shapes (upstream PluginInfo, omitempty semantics) ----

    private func info(_ plugin: Plugin) -> [String: Any] {
        var out: [String: Any] = ["id": plugin.id, "name": plugin.name]
        if !plugin.category.isEmpty { out["category"] = plugin.category }
        if !plugin.author.isEmpty { out["author"] = plugin.author }
        if !plugin.description.isEmpty { out["description"] = plugin.description }
        if !plugin.repo.isEmpty { out["repo"] = plugin.repo }
        if !plugin.path.isEmpty { out["path"] = plugin.path }
        if !plugin.screenshot.isEmpty { out["screenshot"] = plugin.screenshot }
        if !plugin.capabilities.isEmpty { out["capabilities"] = plugin.capabilities }
        if !plugin.compositors.isEmpty { out["compositors"] = plugin.compositors }
        if !plugin.dependencies.isEmpty { out["dependencies"] = plugin.dependencies }
        if !plugin.requiresDMS.isEmpty { out["requires_dms"] = plugin.requiresDMS }
        if plugin.featured { out["featured"] = true }
        if plugin.repo.hasPrefix("https://github.com/AvengeMedia") { out["firstParty"] = true }
        return out
    }

    private func find(_ idOrName: String, in list: [Plugin]) -> Plugin? {
        list.first { $0.id == idOrName } ?? list.first { $0.name == idOrName }
    }

    // Returns (result, error); both nil means "unknown method".
    func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
        switch method {
        case "plugins.list":
            let (list, failure) = self.registryList()
            if let failure { return (nil, "failed to list plugins: \(failure)") }
            let feedback = self.fetchFeedback()
            return (
                list.map { plugin -> [String: Any] in
                    var entry = self.info(plugin)
                    if self.installedPath(for: plugin.id) != nil { entry["installed"] = true }
                    if let fb = feedback[plugin.id] {
                        if let upvotes = fb["upvotes"] as? Int, upvotes != 0 {
                            entry["upvotes"] = upvotes
                        }
                        if let status = fb["status"] as? [String], !status.isEmpty {
                            entry["status"] = status
                        }
                        if let issue = fb["issueUrl"] as? String, !issue.isEmpty {
                            entry["issueUrl"] = issue
                        }
                        if let similar = fb["similar"] as? [String], !similar.isEmpty {
                            entry["similar"] = similar
                        }
                    }
                    return entry
                }, nil
            )
        case "plugins.listInstalled":
            let (list, failure) = self.registryList()
            if let failure { return (nil, "failed to list plugins: \(failure)") }
            let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            return (
                self.listInstalledIDs().map { id -> [String: Any] in
                    guard let plugin = byID[id] else {
                        return ["id": id, "name": id, "note": "not in registry"]
                    }
                    var entry = self.info(plugin)
                    if !plugin.repo.isEmpty { entry["diffUrl"] = plugin.repo }
                    return entry
                }, nil
            )
        case "plugins.search":
            guard let query = params["query"] as? String else {
                return (nil, "missing or invalid 'query' parameter")
            }
            let (list, failure) = self.registryList()
            if let failure { return (nil, "failed to search plugins: \(failure)") }
            let lowered = query.lowercased()
            let matches = lowered.isEmpty
                ? list
                : list.filter { plugin in
                    Self.fuzzyMatch(lowered, plugin.name.lowercased())
                        || Self.fuzzyMatch(lowered, plugin.category.lowercased())
                        || Self.fuzzyMatch(lowered, plugin.description.lowercased())
                        || Self.fuzzyMatch(lowered, plugin.author.lowercased())
                }
            return (matches.map { self.info($0) }, nil)
        case "plugins.install", "plugins.uninstall", "plugins.update":
            guard let idOrName = params["name"] as? String else {
                return (nil, "missing or invalid 'name' parameter")
            }
            let (list, failure) = self.registryList()
            if let failure { return (nil, "failed to list plugins: \(failure)") }
            guard let plugin = self.find(idOrName, in: list) else {
                return (nil, "plugin not found: \(idOrName)")
            }
            let verb: String
            let outcome: String?
            switch method {
            case "plugins.install":
                verb = "installed"
                outcome = self.install(plugin).map { "failed to install plugin: \($0)" }
            case "plugins.uninstall":
                verb = "uninstalled"
                outcome = self.uninstall(plugin).map { "failed to uninstall plugin: \($0)" }
            default:
                verb = "updated"
                outcome = self.update(plugin).map { "failed to update plugin: \($0)" }
            }
            if let outcome { return (nil, outcome) }
            return (["success": true, "message": "plugin \(verb): \(plugin.name)"], nil)
        default:
            return (nil, nil)
        }
    }
}
