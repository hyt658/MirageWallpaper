//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
@testable import Mirage_Wallpaper

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String: [[String: Any]]] = [:]
    private var exits: [String: Int] = [:]
    func event(_ handle: RendererProcess, _ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        messages[handle.endpointID, default: []].append(event)
    }
    func exited(_ handle: RendererProcess) {
        lock.lock(); defer { lock.unlock() }
        exits[handle.endpointID, default: 0] += 1
    }
    func has(_ name: String, _ handle: RendererProcess) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return messages[handle.endpointID, default: []].contains { $0["event"] as? String == name }
    }
    func exitCount(_ handle: RendererProcess) -> Int {
        lock.lock(); defer { lock.unlock() }
        return exits[handle.endpointID, default: 0]
    }
}

private struct Failure: Error, CustomStringConvertible { let description: String }

@main
private struct SharedVideoPlaybackRegression {
    @MainActor
    static func wait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            if Date() > deadline { throw Failure(description: description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw Failure(description: description) }
    }

    static func runMockRenderer() {
        var failures: [String: Bool] = [:]
        func emit(_ name: String, _ endpoint: String) {
            let data = try! JSONSerialization.data(withJSONObject: ["event": name, "endpoint": endpoint])
            FileHandle.standardOutput.write(data + Data([0x0A]))
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = command["cmd"] as? String else { continue }
            if name == "quit" { return }
            guard let token = command["endpoint"] as? String else { continue }
            switch name {
            case "attach":
                failures[token] = command["speed"] as? Double == 1.5
                emit("prepared", token)
            case "activate": emit(failures[token] == true ? "activation-failed" : "activated", token)
            case "deactivate": emit("deactivated", token)
            case "detach":
                failures[token] = nil
                emit("deactivated", token)
                emit("detached", token)
            default: break
            }
        }
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--control-stdin") { runMockRenderer(); return }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let binary = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: root.appending(path: "project.json"))
        let wallpaper = WEWallpaper(using: try JSONDecoder().decode(WEProject.self, from: data), where: root)
        let display = CGMainDisplayID()
        var options = RenderOptions()
        options.shareVideoPlayback = true
        options.volume = 0
        options.muted = true
        let events = Events()
        let callbacks = DispatchQueue(label: "mirage.shared-video.regression")
        func host() throws -> SharedVideoProcess {
            let host = SharedVideoProcess(binary: binary, wallpaper: wallpaper, options: options,
                callbackQueue: callbacks, onEvent: { events.event($0, $1) },
                onExit: { handle, _ in events.exited(handle) }, onClose: { _ in })
            try host.start()
            return host
        }
        func attach(_ host: SharedVideoProcess, generation: UInt64) -> RendererProcess {
            let transport = host.transport
            let handle = RendererProcess(process: transport.process, stdinPipe: transport.stdinPipe,
                stdoutPipe: nil, stderrPipe: transport.stderrPipe, wallpaper: wallpaper,
                displayID: display, generation: generation, options: options,
                spectrumEnabled: false, sharedVideoHost: host)
            host.attach(handle, options: options)
            return handle
        }
        let firstHost = try host()
        let first = attach(firstHost, generation: 1)
        let second = attach(firstHost, generation: 2)
        defer { firstHost.transport.forceKill() }
        try await wait("both native endpoints prepared") { events.has("prepared", first) && events.has("prepared", second) }
        first.send(["cmd": "activate"])
        second.send(["cmd": "activate"])
        try await wait("both native endpoints activated") { events.has("activated", first) && events.has("activated", second) }
        try check(first.process === second.process, "physical process was duplicated")
        first.stop()
        try await wait("first endpoint detached") { !first.isRunning && events.exitCount(first) == 1 }
        // Calling escalation on an already detached endpoint must not kill a
        // live host that still belongs to another display.
        first.forceTerminate()
        first.forceKill()
        try check(second.isRunning && firstHost.canAttach, "detachment killed another display")
        second.send(["cmd": "shared-status"])
        try await wait("remaining endpoint still responds") { events.has("shared-status", second) }
        let third = attach(firstHost, generation: 3)
        try await wait("late endpoint prepared") { events.has("prepared", third) }
        firstHost.transport.forceKill()
        try await wait("host crash reaches every live endpoint") {
            events.exitCount(second) == 1 && events.exitCount(third) == 1
        }
        try check(!second.isRunning && !third.isRunning && !firstHost.canAttach,
                  "crashed endpoints remained live")
        try check(events.exitCount(first) == 1, "detached endpoint received a second exit")
        let finalHost = try host()
        let final = attach(finalHost, generation: 4)
        defer { finalHost.transport.forceKill() }
        try await wait("replacement host prepared") { events.has("prepared", final) }
        final.stop()
        try await wait("last endpoint releases physical process") {
            !finalHost.transport.process.isRunning && events.exitCount(final) == 1
        }

        // Settings written before this feature must retain independent playback.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GlobalSettings())) as! [String: Any]
        legacy.removeValue(forKey: "shareVideoPlayback")
        let restored = try JSONDecoder().decode(GlobalSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        try check(!restored.shouldShareVideoPlayback, "legacy settings enabled sharing")

        // Exercise the real controller's switch and synchronous shutdown paths.
        let controller = RendererController()
        defer { controller.stopAllAndWait() }
        var completed: Bool?
        controller.render(wallpaper, onDisplay: display, options: options) { completed = $0 }
        try await wait("shared controller activation") { completed != nil }
        try check(completed == true && controller.isRendering(onDisplay: display), "shared controller failed")
        let sharedPID = controller.processIdentifiers.first!
        completed = nil
        options.shareVideoPlayback = false
        controller.render(wallpaper, onDisplay: display, options: options, reuseActive: true) { completed = $0 }
        try await wait("switch from shared to independent") { completed != nil }
        try check(completed == true && !controller.processIdentifiers.contains(sharedPID),
                  "same-wallpaper reuse ignored the sharing mode")
        completed = nil
        options.shareVideoPlayback = true
        controller.render(wallpaper, onDisplay: display, options: options, reuseActive: true) { completed = $0 }
        try await wait("switch back to shared") { completed != nil }
        try check(completed == true, "switching back to sharing failed")
        let activePIDs = controller.processIdentifiers
        controller.stopAllAndWait()
        try check(controller.processIdentifiers.isEmpty, "shutdown retained registered processes")
        for pid in activePIDs { try check(kill(pid, 0) != 0, "synchronous shutdown left a process alive") }
        // A protocol fixture exercises controller pooling across display IDs
        // even on a machine with only one physical screen. Real presentation
        // and transport behaviour were exercised above using AVFoundation.
        let renderers = Bundle.main.resourceURL!.appending(path: "Renderers")
        try FileManager.default.createDirectory(at: renderers, withIntermediateDirectories: true)
        let override = renderers.appending(path: "VideoWallpaper")
        try FileManager.default.createSymbolicLink(at: override,
            withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        defer { try? FileManager.default.removeItem(at: override) }
        let pooled = RendererController()
        defer { pooled.stopAllAndWait() }
        var firstDone: Bool?, secondDone: Bool?
        pooled.render(wallpaper, onDisplay: 9001, options: options) { firstDone = $0 }
        pooled.render(wallpaper, onDisplay: 9002, options: options) { secondDone = $0 }
        try await wait("both simulated displays activate") { firstDone != nil && secondDone != nil }
        try check(firstDone == true && secondDone == true && pooled.processIdentifiers.count == 1,
                  "controller did not pool the same video across displays")
        let pooledPID = pooled.processIdentifiers.first!
        var rejected: Bool?
        var failureOptions = options
        failureOptions.speed = 1.5
        pooled.render(wallpaper, onDisplay: 9001, options: failureOptions) { rejected = $0 }
        try await wait("failed candidate restores its sibling in the same process") { rejected != nil }
        try check(rejected == false && pooled.isRendering(onDisplay: 9001) &&
                  pooled.isRendering(onDisplay: 9002) && pooled.processIdentifiers == [pooledPID],
                  "shared candidate rollback damaged another endpoint")
        var finishes = 0
        var lastSucceeded = false
        for index in 0..<50 {
            pooled.render(wallpaper, onDisplay: 9001, options: options) { success in
                finishes += 1
                if index == 49 { lastSucceeded = success }
            }
        }
        try await wait("rapid shared assignments settle") { finishes == 50 }
        try check(lastSucceeded && pooled.processIdentifiers == [pooledPID] && pooled.isRendering(onDisplay: 9002),
                  "rapid shared switching lost process ownership or display isolation")
        pooled.stop(displayID: 9001)
        try await wait("one pooled display stops") { !pooled.isRendering(onDisplay: 9001) }
        try check(pooled.isRendering(onDisplay: 9002) && kill(pooledPID, 0) == 0,
                  "stopping one pooled display killed the shared process")
        pooled.stop(displayID: 9002)
        try await wait("last pooled display releases its process") {
            pooled.processIdentifiers.isEmpty && kill(pooledPID, 0) != 0
        }
        print("SharedVideoPlaybackRegression: native transport, crash fan-out, mode switching, legacy settings, pooling, rollback, 50 rapid switches, display isolation and shutdown passed")
    }
}
