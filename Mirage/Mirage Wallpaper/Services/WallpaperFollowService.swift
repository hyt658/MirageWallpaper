//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import Combine

// Configuration publication also happens on background queues. Cancellation and
// the final atomic write must share a lock, including manual configuration jobs.
final class WallpaperConfigurationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    func begin() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        current = id
        return id
    }

    func cancel(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if current == id { current = nil }
    }

    func perform<T>(_ id: UUID, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard current == id else { throw CancellationError() }
        return try operation()
    }
}

@MainActor
protocol WallpaperFollowEnvironment {
    var displays: [DisplayInfo] { get }
    var mainDisplayKey: DisplayKey? { get }
    var screenSaverInstalled: Bool { get }
    var lockScreenMode: DynamicLockScreenMode? { get }
    func state(for key: DisplayKey) -> DisplayWallpaperState?
    func installScreenSaver() async throws
    func synchronize(_ target: WallpaperFollowService.Target, from key: DisplayKey,
                     wallpaper: WEWallpaper) async throws
}

@MainActor
final class WallpaperFollowService: ObservableObject {
    static let shared = WallpaperFollowService(environment: SystemWallpaperFollowEnvironment())

    enum Target: CaseIterable, Hashable { case screenSaver, lockScreen }

    enum Status: Equatable {
        case off, waitingForDisplay, waitingForWallpaper, unsupportedWallpaper
        case waitingForScreenSaver, waitingForLockScreen, synchronizing, manual
        case synchronized(String), failed(String)

        var message: String {
            switch self {
            case .off: return L("自动跟随已关闭")
            case .waitingForDisplay: return L("跟随来源未连接，保留上次配置")
            case .waitingForWallpaper: return L("等待来源显示器播放壁纸，保留上次配置")
            case .unsupportedWallpaper: return L("当前作品不支持屏保或动态锁屏，保留上次配置")
            case .waitingForScreenSaver: return L("请安装 Mirage 屏保组件以继续跟随")
            case .waitingForLockScreen: return L("请先启用动态锁屏方案并完成确认")
            case .synchronizing: return L("正在同步壁纸…")
            case .manual: return L("已暂停自动跟随，将在下次桌面指派时恢复")
            case .synchronized(let title): return L("已同步：%@", title)
            case .failed(let message): return L("同步失败：%@", message)
            }
        }
    }

    struct Options: Equatable {
        var screenSaver: Bool
        var lockScreen: Bool
        var source: String?

        init(_ settings: GlobalSettings = GlobalSettings()) {
            screenSaver = settings.screenSaverFollowsDesktop ?? false
            lockScreen = settings.lockScreenFollowsDesktop ?? false
            source = settings.wallpaperFollowDisplayKey
        }

        func enabled(_ target: Target) -> Bool {
            target == .screenSaver ? screenSaver : lockScreen
        }
    }

    private struct Selection {
        let source: DisplayKey
        let wallpaper: WEWallpaper
        let mode: DynamicLockScreenMode?
        let displayIDs: [UInt32]

        func matches(_ other: Selection) -> Bool {
            source == other.source && mode == other.mode && displayIDs == other.displayIDs &&
                wallpaper.hasSamePresentation(as: other.wallpaper)
        }
    }

    @Published private(set) var screenSaverStatus = Status.off
    @Published private(set) var lockScreenStatus = Status.off
    private let environment: any WallpaperFollowEnvironment
    private var options = Options()
    private var started = false
    private var desired: [Target: Selection] = [:]
    private var completed: [Target: Selection] = [:]
    private var running: [Target: Selection] = [:]
    private var tasks: [Target: Task<Void, Never>] = [:]
    private var manualOverrides: Set<Target> = []
    private var installation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(environment: any WallpaperFollowEnvironment) {
        self.environment = environment
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
        installation?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(settings: GlobalSettings, observeSystem: Bool = true) {
        guard !started else { return }
        started = true
        options = Options(settings)
        if observeSystem {
            for name in [DisplayRegistry.didChangeNotification, DynamicLockScreenModeStore.didChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            if name == DynamicLockScreenModeStore.didChangeNotification {
                                self?.completed[.lockScreen] = nil
                                self?.cancel(.lockScreen)
                            }
                            self?.refresh()
                        }
                    })
            }
        }
        refresh()
    }

    func stop() {
        started = false
        Target.allCases.forEach(cancel)
        installation?.cancel()
        installation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func apply(settings: GlobalSettings) {
        guard started else { return }
        let updated = Options(settings)
        guard updated != options else { return }
        let previous = options
        let shouldInstall = updated.screenSaver && !options.screenSaver
        options = updated
        for target in Target.allCases where previous.source != updated.source ||
            previous.enabled(target) != updated.enabled(target) {
            manualOverrides.remove(target)
            completed[target] = nil
            cancel(target)
        }
        if !updated.screenSaver { installation?.cancel() }
        refresh()
        if shouldInstall { installScreenSaverIfNeeded() }
    }

    func assignmentDidCommit(on key: DisplayKey) {
        guard started, key == sourceDisplayKey else { return }
        manualOverrides.removeAll()
        refresh()
    }

    func beginManualConfiguration(_ target: Target) {
        guard started else { return }
        manualOverrides.insert(target)
        completed[target] = nil
        cancel(target)
        if options.enabled(target) { setStatus(.manual, for: target) }
    }

    func retry(_ target: Target) {
        guard started else { return }
        manualOverrides.remove(target)
        completed[target] = nil
        cancel(target)
        refresh(target)
        if target == .screenSaver { installScreenSaverIfNeeded() }
    }

    func refresh() {
        guard started else { return }
        Target.allCases.forEach(refresh)
    }

    private var sourceDisplayKey: DisplayKey? {
        options.source.map(DisplayKey.init(rawValue:)) ?? environment.mainDisplayKey
    }

    private func refresh(_ target: Target) {
        guard options.enabled(target) else {
            completed[target] = nil
            wait(.off, for: target)
            return
        }
        guard !manualOverrides.contains(target) else { return }
        guard let source = sourceDisplayKey, environment.displays.contains(where: { $0.key == source }) else {
            wait(.waitingForDisplay, for: target)
            return
        }
        guard let state = environment.state(for: source), state.wallpaper.isValid else {
            wait(.waitingForWallpaper, for: target)
            return
        }
        guard state.wallpaper.kind == .video || state.wallpaper.kind == .scene else {
            wait(.unsupportedWallpaper, for: target)
            return
        }
        if target == .screenSaver, !environment.screenSaverInstalled {
            completed[target] = nil
            wait(installation == nil ? .waitingForScreenSaver : .synchronizing, for: target)
            return
        }
        if target == .lockScreen, environment.lockScreenMode == nil {
            completed[target] = nil
            wait(.waitingForLockScreen, for: target)
            return
        }
        let mode = target == .lockScreen ? environment.lockScreenMode : nil
        let selection = Selection(source: source, wallpaper: state.wallpaper, mode: mode,
            displayIDs: mode == .extensionMode ? environment.displays.map(\.displayID).sorted() : [])
        if let previous = completed[target], previous.matches(selection), tasks[target] == nil {
            setStatus(.synchronized(state.wallpaper.project.title), for: target)
            return
        }
        desired[target] = selection
        if let task = tasks[target] {
            if running[target]?.matches(selection) != true { task.cancel() }
            setStatus(.synchronizing, for: target)
            return
        }
        setStatus(.synchronizing, for: target)
        // A worker may publish just before cancellation reaches it. Once a new
        // writer starts, an older successful selection is no longer proof of
        // what is on disk (including when the user switches back to it).
        completed[target] = nil
        running[target] = selection
        tasks[target] = Task { @MainActor [weak self, environment] in
            let result: Result<Void, Error>
            do {
                // Coalesce clicks and playlist commits before doing deployment IO.
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                try await environment.synchronize(target, from: source, wallpaper: selection.wallpaper)
                try Task.checkCancellation()
                result = .success(())
            } catch { result = .failure(error) }
            guard let self else { return }
            self.tasks[target] = nil
            self.running[target] = nil
            guard self.started else { return }
            guard !Task.isCancelled, self.desired[target]?.matches(selection) == true else {
                self.refresh(target)
                return
            }
            switch result {
            case .success:
                self.completed[target] = selection
                self.setStatus(.synchronized(selection.wallpaper.project.title), for: target)
            case .failure(let error):
                if error is CancellationError {
                    self.refresh(target)
                } else {
                    self.setStatus(.failed(error.localizedDescription), for: target)
                    MirageLogService.shared.append(error.localizedDescription, source: "wallpaper-follow")
                }
            }
        }
    }

    private func installScreenSaverIfNeeded() {
        guard options.screenSaver, !environment.screenSaverInstalled, installation == nil else { return }
        installation = Task { @MainActor [weak self, environment] in
            do {
                try Task.checkCancellation()
                try await environment.installScreenSaver()
                try Task.checkCancellation()
                self?.installation = nil
                self?.refresh(.screenSaver)
            } catch {
                self?.installation = nil
                guard let self, self.started, self.options.screenSaver else { return }
                if Task.isCancelled {
                    self.refresh(.screenSaver)
                    return
                }
                self.setStatus(.failed(error.localizedDescription), for: .screenSaver)
                MirageLogService.shared.append(error.localizedDescription, source: "wallpaper-follow")
            }
        }
        setStatus(.synchronizing, for: .screenSaver)
    }

    private func cancel(_ target: Target) {
        desired[target] = nil
        tasks[target]?.cancel()
    }

    private func wait(_ status: Status, for target: Target) {
        cancel(target)
        setStatus(status, for: target)
    }

    private func setStatus(_ status: Status, for target: Target) {
        if target == .screenSaver {
            if screenSaverStatus != status { screenSaverStatus = status }
        } else if lockScreenStatus != status { lockScreenStatus = status }
    }
}

@MainActor
private struct SystemWallpaperFollowEnvironment: WallpaperFollowEnvironment {
    var displays: [DisplayInfo] { DisplayRegistry.shared.connected }
    var mainDisplayKey: DisplayKey? { DisplayRegistry.shared.mainKey }
    var screenSaverInstalled: Bool { ScreenSaverManager.shared.isInstalled }
    var lockScreenMode: DynamicLockScreenMode? {
        switch DynamicLockScreenModeStore.active {
        case .extensionMode:
            let manager = DynamicLockScreenManager.shared
            return manager.isAvailable && manager.isEnabled && manager.hasConfirmedWarning ? .extensionMode : nil
        case .screenSaver:
            let manager = ScreenSaverDynamicLockScreenManager.shared
            return manager.isAvailable && manager.isEnabled && manager.hasConfirmedWarning ? .screenSaver : nil
        case nil: return nil
        }
    }

    func state(for key: DisplayKey) -> DisplayWallpaperState? {
        AppDelegate.shared.wallpaperViewModel.state(for: key)
    }

    func installScreenSaver() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try ScreenSaverManager.shared.install() })
            }
        }
    }

    func synchronize(_ target: WallpaperFollowService.Target, from key: DisplayKey,
                     wallpaper: WEWallpaper) async throws {
        let model = AppDelegate.shared.wallpaperViewModel
        guard let current = state(for: key), current.wallpaper.hasSamePresentation(as: wallpaper) else {
            throw CancellationError()
        }
        let fps = Int(AppDelegate.shared.globalSettingsViewModel.savedSettings.fps)
        if target == .lockScreen {
            switch lockScreenMode {
            case .extensionMode:
                try await DynamicLockScreenManager.shared.configureCurrentWallpaper(
                    wallpaper, runtime: current.runtime,
                    properties: model.effectiveProperties(for: wallpaper, runtime: current.runtime),
                    fps: fps, displayIDs: displays.map(\.displayID), sourceDisplay: key)
            case .screenSaver:
                try await ScreenSaverDynamicLockScreenManager.shared.configureCurrentWallpaper(
                    wallpaper, runtime: current.runtime,
                    properties: model.effectiveProperties(for: wallpaper, runtime: current.runtime),
                    fps: fps, sourceDisplay: key)
            case nil: throw CancellationError()
            }
            return
        }
        let manager = ScreenSaverManager.shared
        let requestID = manager.beginConfigurationRequest()
        try await withTaskCancellationHandler {
            await model.refreshScriptStorage(for: wallpaper)
            try Task.checkCancellation()
            guard let latest = state(for: key), latest.wallpaper.hasSamePresentation(as: wallpaper),
                  screenSaverInstalled else { throw CancellationError() }
            let properties = model.effectiveProperties(for: wallpaper, runtime: latest.runtime)
            let context = ScreenSaverManager.ConfigurationContext(
                wallpaperID: wallpaper.id, runtime: latest.runtime, fps: fps, sourceDisplay: key)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try ScreenSaverManager.shared.configure(
                            with: wallpaper, runtime: latest.runtime, properties: properties,
                            fps: fps, context: context, requestID: requestID)
                    })
                }
            }
            try Task.checkCancellation()
            // Properties may have changed while the background writer was
            // preparing the configuration. Publish the latest runtime as well.
            model.saveRuntime()
        } onCancel: { ScreenSaverManager.shared.cancelConfigurationRequest(requestID) }
    }
}
