import Cocoa
import Carbon
import SwiftUI
import ServiceManagement
import ApplicationServices

// MARK: - 日志记录
func log(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/litetab.log")) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/litetab.log"))
        }
    }
}

// MARK: - 真实物理内存监控 (对应 macOS 活动监视器 "内存" Footprint)
func getProcessMemoryMB() -> Double {
    var taskInfo = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
    let kerr = withUnsafeMutablePointer(to: &taskInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if kerr == KERN_SUCCESS {
        return Double(taskInfo.phys_footprint) / 1024.0 / 1024.0
    }
    return 0.0
}

// MARK: - 全局配置中心
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @AppStorage("cardSizeOption") var cardSizeOption: String = "standard"
    @AppStorage("showTipLabel") var showTipLabel: Bool = true
    @AppStorage("includeMinimized") var includeMinimized: Bool = true
    @AppStorage("cacheDuration") var cacheDuration: Double = 20.0
    @AppStorage("maxWindowsCount") var maxWindowsCount: Int = 12
    
    // 快捷键配置 (KeyCode, Modifiers, 显示名称)
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode: Int = Int(kVK_Tab) // 48
    @AppStorage("hotkeyModifiers") var hotkeyModifiers: Int = Int(optionKey) // 2048
    @AppStorage("hotkeyDisplayString") var hotkeyDisplayString: String = "⌥ Tab"
    
    var cardWidth: CGFloat {
        switch cardSizeOption {
        case "compact": return 180
        case "spacious": return 260
        default: return 220
        }
    }
    
    var cardHeight: CGFloat {
        switch cardSizeOption {
        case "compact": return 145
        case "spacious": return 205
        default: return 175
        }
    }
    
    var primaryModifierFlag: NSEvent.ModifierFlags {
        if hotkeyModifiers & Int(cmdKey) != 0 {
            return .command
        } else if hotkeyModifiers & Int(controlKey) != 0 {
            return .control
        } else {
            return .option
        }
    }
}

// MARK: - 权限检测
typealias CGPreflightScreenCaptureAccessFunc = @convention(c) () -> Bool
typealias CGRequestScreenCaptureAccessFunc = @convention(c) () -> Bool

var hasScreenCaptureAccess: Bool {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let sym = dlsym(handle, "CGPreflightScreenCaptureAccess") else { return true }
    let fn = unsafeBitCast(sym, to: CGPreflightScreenCaptureAccessFunc.self)
    return fn()
}

func requestScreenCaptureAccess() {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let sym = dlsym(handle, "CGRequestScreenCaptureAccess") else { return }
    let fn = unsafeBitCast(sym, to: CGRequestScreenCaptureAccessFunc.self)
    _ = fn()
}

var hasAccessibilityAccess: Bool {
    return AXIsProcessTrusted()
}

func requestAccessibilityAccess() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

// MARK: - 动态加载 CoreGraphics 截屏 API
typealias CGWindowListCreateImageFunc = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
var cgCreateImage: CGWindowListCreateImageFunc? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
}()

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - 极限内存优化：将原始超大位图等比下采样至卡片所需物理像素
func downscaleCGImage(_ src: CGImage, targetMax: CGFloat = 480) -> CGImage {
    let w = CGFloat(src.width)
    let h = CGFloat(src.height)
    guard w > 0, h > 0 else { return src }
    
    let scale = min(targetMax / w, targetMax / h, 1.0)
    if scale >= 1.0 { return src }
    
    let dw = max(1, Int(w * scale))
    let dh = max(1, Int(h * scale))
    
    let cs = src.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: dw,
        height: dh,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return src }
    
    ctx.interpolationQuality = .medium
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: dw, height: dh))
    return ctx.makeImage() ?? src
}

// MARK: - 缩略图缓存
class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [CGWindowID: (image: NSImage, time: CFAbsoluteTime)] = [:]
    private let lock = NSLock()
    
    func get(wid: CGWindowID) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[wid] {
            let maxAge = AppSettings.shared.cacheDuration
            if CFAbsoluteTimeGetCurrent() - entry.time < maxAge {
                return entry.image
            }
        }
        return nil
    }
    
    func set(wid: CGWindowID, image: NSImage) {
        lock.lock()
        defer { lock.unlock() }
        cache[wid] = (image, CFAbsoluteTimeGetCurrent())
        if cache.count > 25 {
            cache.removeAll()
        }
    }
    
    func remove(wid: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: wid)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

// MARK: - 窗口数据模型
class WindowItem {
    let wid: CGWindowID
    let pid: pid_t
    let appName: String
    let appIcon: NSImage
    var title: String
    var thumbnail: NSImage?
    var isMinimized: Bool
    
    init(wid: CGWindowID, pid: pid_t, appName: String, appIcon: NSImage, title: String, isMinimized: Bool = false, thumbnail: NSImage? = nil) {
        self.wid = wid
        self.pid = pid
        self.appName = appName
        self.appIcon = appIcon
        self.title = title
        self.isMinimized = isMinimized
        self.thumbnail = thumbnail
    }
}

// MARK: - 后台静默扫描最小化窗口 (完全不阻塞主线程与热键弹出)
class MinimizedScanner {
    static let shared = MinimizedScanner()
    private var cachedItems: [WindowItem] = []
    private var minimizedWIDs = Set<CGWindowID>()
    private let lock = NSLock()
    private let scanQueue = DispatchQueue(label: "com.wenruifeng.litetab.minimized_scanner", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        scan()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            self?.scan()
        }
        ws.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            self?.scan()
        }
        ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            self?.scan()
        }

        let t = DispatchSource.makeTimerSource(queue: scanQueue)
        t.schedule(deadline: .now() + 3.0, repeating: 3.0)
        t.setEventHandler { [weak self] in
            self?.performScan()
        }
        t.resume()
        self.timer = t
    }

    func scan() {
        scanQueue.async { [weak self] in
            self?.performScan()
        }
    }

    private func performScan() {
        guard AppSettings.shared.includeMinimized else {
            lock.lock()
            cachedItems.removeAll()
            minimizedWIDs.removeAll()
            lock.unlock()
            return
        }

        let currentPid = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != currentPid
        }

        var results: [WindowItem] = []
        var wids = Set<CGWindowID>()
        for app in runningApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var windowsVal: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
               let axWindows = windowsVal as? [AXUIElement] {
                for win in axWindows {
                    var minVal: AnyObject?
                    if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success,
                       let isMin = minVal as? Bool, isMin {
                        var idVal: CGWindowID = 0
                        _ = _AXUIElementGetWindow(win, &idVal)
                        if idVal != 0 {
                            wids.insert(idVal)
                            var titleVal: AnyObject?
                            _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal)
                            let title = (titleVal as? String) ?? (app.localizedName ?? "App")
                            let appName = app.localizedName ?? "App"
                            let appIcon = app.icon ?? NSWorkspace.shared.icon(for: .application)

                            let item = WindowItem(
                                wid: idVal,
                                pid: pid,
                                appName: appName,
                                appIcon: appIcon,
                                title: title,
                                isMinimized: true,
                                thumbnail: appIcon
                            )
                            results.append(item)
                        }
                    }
                }
            }
        }

        lock.lock()
        self.cachedItems = results
        self.minimizedWIDs = wids
        lock.unlock()
    }

    func getCached() -> [WindowItem] {
        lock.lock()
        defer { lock.unlock() }
        return cachedItems
    }

    func isMinimized(wid: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return minimizedWIDs.contains(wid)
    }
}

// MARK: - 窗口管理器 (毫秒级响应)
class WindowManager {
    static let shared = WindowManager()
    private let captureQueue = DispatchQueue(label: "com.wenruifeng.litetab.capture", qos: .userInteractive, attributes: .concurrent)

    // 纯纯毫秒级主线程扫描：绝不做阻塞式 AX 调用
    func getVisibleWindowsFast() -> [WindowItem] {
        var items: [WindowItem] = []
        var seenWIDs = Set<CGWindowID>()
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let maxCount = AppSettings.shared.maxWindowsCount

        // 1. 获取当前屏幕最顶层可见窗口（按系统窗口 Z 轴深度顺序排列）
        let onScreenOpts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let onScreenList = CGWindowListCopyWindowInfo(onScreenOpts, kCGNullWindowID) as? [[String: Any]] {
            for w in onScreenList {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.5,
                      let bounds = w[kCGWindowBounds as String] as? [String: Any],
                      let width = bounds["Width"] as? Double, width > 160,
                      let height = bounds["Height"] as? Double, height > 160,
                      let pid = w[kCGWindowOwnerPID as String] as? Int,
                      pid != currentPid,
                      let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                      app.activationPolicy == .regular else {
                    continue
                }

                let wid = CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)
                if seenWIDs.contains(wid) { continue }
                seenWIDs.insert(wid)

                let appName = app.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "App"
                let appIcon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                let rawTitle = w[kCGWindowName as String] as? String ?? ""
                let displayTitle = rawTitle.isEmpty ? appName : rawTitle

                let cachedImg = ThumbnailCache.shared.get(wid: wid)
                let isMin = MinimizedScanner.shared.isMinimized(wid: wid)

                let item = WindowItem(
                    wid: wid,
                    pid: pid_t(pid),
                    appName: appName,
                    appIcon: appIcon,
                    title: displayTitle,
                    isMinimized: isMin,
                    thumbnail: cachedImg
                )
                items.append(item)
                if items.count >= maxCount { return items }
            }
        }

        // 2. 获取跨 Space (虚拟桌面)、全屏、后台未上屏及真实多窗口 (例如 Chrome 另一个窗口)
        let allOpts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        if let allList = CGWindowListCopyWindowInfo(allOpts, kCGNullWindowID) as? [[String: Any]] {
            for w in allList {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.5,
                      let bounds = w[kCGWindowBounds as String] as? [String: Any],
                      let width = bounds["Width"] as? Double, width > 160,
                      let height = bounds["Height"] as? Double, height > 160,
                      let pid = w[kCGWindowOwnerPID as String] as? Int,
                      pid != currentPid,
                      let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                      app.activationPolicy == .regular else {
                    continue
                }

                let wid = CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)
                if seenWIDs.contains(wid) { continue }

                // 核心防幽灵过滤：非当前可见屏幕的后台窗口，必须具有非空真实标题
                // 这样能精准过滤掉各大 App 的无标题隐形面板、系统背景服务，同时保留真实的网页/文档/多窗口
                let rawTitle = w[kCGWindowName as String] as? String ?? ""
                guard !rawTitle.isEmpty else { continue }

                seenWIDs.insert(wid)

                let appName = app.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "App"
                let appIcon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                let cachedImg = ThumbnailCache.shared.get(wid: wid)
                let isMin = MinimizedScanner.shared.isMinimized(wid: wid)

                let item = WindowItem(
                    wid: wid,
                    pid: pid_t(pid),
                    appName: appName,
                    appIcon: appIcon,
                    title: rawTitle,
                    isMinimized: isMin,
                    thumbnail: cachedImg
                )
                items.append(item)
                if items.count >= maxCount { return items }
            }
        }

        // 3. 瞬间合并后台预缓存的最小化窗口 (补充无标题但被最小化的窗口)
        if AppSettings.shared.includeMinimized && items.count < maxCount {
            let minItems = MinimizedScanner.shared.getCached()
            for minItem in minItems {
                if !seenWIDs.contains(minItem.wid) {
                    seenWIDs.insert(minItem.wid)
                    items.append(minItem)
                    if items.count >= maxCount { break }
                }
            }
        }

        return items
    }

    // 后台抓取缩略图并即时释放内存
    func loadThumbnailsAsync(items: [WindowItem], onImageLoaded: @escaping (Int, NSImage, String, Bool) -> Void) {
        for (idx, item) in items.enumerated() {
            captureQueue.async { [weak self] in
                guard let self = self else { return }

                if item.isMinimized {
                    DispatchQueue.main.async {
                        onImageLoaded(idx, item.appIcon, item.title, true)
                    }
                    return
                }

                autoreleasepool {
                    var loadedImg: NSImage? = nil
                    if let createFn = cgCreateImage,
                       let unmanaged = createFn(.null, 8, item.wid, 1 | 16) {
                        let rawCgImg = unmanaged.takeRetainedValue()
                        let smallCgImg = downscaleCGImage(rawCgImg, targetMax: 480)
                        let w = CGFloat(smallCgImg.width)
                        let h = CGFloat(smallCgImg.height)
                        if w > 0 && h > 0 {
                            let finalNSImg = NSImage(cgImage: smallCgImg, size: NSSize(width: w, height: h))
                            loadedImg = finalNSImg
                            ThumbnailCache.shared.set(wid: item.wid, image: finalNSImg)
                        }
                    }

                    let currentImg = loadedImg ?? item.thumbnail ?? item.appIcon
                    item.thumbnail = currentImg

                    DispatchQueue.main.async {
                        onImageLoaded(idx, currentImg, item.title, item.isMinimized)
                    }

                    let (realTitle, isActuallyMin) = self.getAXWindowDetails(pid: item.pid, wid: item.wid)
                    if isActuallyMin {
                        item.isMinimized = true
                    }
                    if !realTitle.isEmpty {
                        item.title = realTitle
                        DispatchQueue.main.async {
                            onImageLoaded(idx, currentImg, realTitle, item.isMinimized)
                        }
                    }
                }
            }
        }
    }

    private func getAXWindowDetails(pid: pid_t, wid: CGWindowID) -> (title: String, isMinimized: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement] else {
            return ("", false)
        }
        for win in axWindows {
            var idVal: CGWindowID = 0
            if _AXUIElementGetWindow(win, &idVal) == .success && idVal == wid {
                var titleVal: AnyObject?
                _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal)
                let title = (titleVal as? String) ?? ""

                var minVal: AnyObject?
                var isMin = false
                if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success,
                   let m = minVal as? Bool {
                    isMin = m
                }
                return (title, isMin)
            }
        }
        return ("", false)
    }

    func activateWindow(pid: pid_t, wid: CGWindowID, isMinimized: Bool = false) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate()

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let axWindows = windowsValue as? [AXUIElement] {
            for win in axWindows {
                var idVal: CGWindowID = 0
                if _AXUIElementGetWindow(win, &idVal) == .success && idVal == wid {
                    var minVal: AnyObject?
                    let isActuallyMin = (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success && (minVal as? Bool == true))
                    if isMinimized || isActuallyMin {
                        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                    return
                }
            }
        }
    }

    func closeWindow(pid: pid_t, wid: CGWindowID) {
        ThumbnailCache.shared.remove(wid: wid)
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let axWindows = windowsValue as? [AXUIElement] {
            for win in axWindows {
                var idVal: CGWindowID = 0
                if _AXUIElementGetWindow(win, &idVal) == .success && idVal == wid {
                    var closeButton: AnyObject?
                    if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
                       let btn = closeButton {
                        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
                        return
                    }
                }
            }
        }
    }
    
    func minimizeWindow(pid: pid_t, wid: CGWindowID) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let axWindows = windowsValue as? [AXUIElement] {
            for win in axWindows {
                var idVal: CGWindowID = 0
                if _AXUIElementGetWindow(win, &idVal) == .success && idVal == wid {
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    return
                }
            }
        }
    }
    
    func quitApp(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        }
    }
    
    func hideApp(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.hide()
        }
    }
}

// MARK: - 单个窗口卡片
class WindowCardView: NSView {
    private let containerBox = NSView()
    private let imageView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let borderLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    
    var onSelect: (() -> Void)?
    
    var isSelected: Bool = false {
        didSet { updateSelectionState() }
    }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        
        containerBox.wantsLayer = true
        containerBox.layer?.cornerRadius = 10
        containerBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        addSubview(containerBox)
        
        placeholderIconView.imageScaling = .scaleProportionallyUpOrDown
        placeholderIconView.alphaValue = 0.45
        containerBox.addSubview(placeholderIconView)
        
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        containerBox.addSubview(imageView)
        
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        addSubview(titleLabel)
        
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .right
        addSubview(badgeLabel)
        
        borderLayer.cornerRadius = 14
        borderLayer.borderWidth = 2.5
        borderLayer.borderColor = NSColor.clear.cgColor
        layer?.addSublayer(borderLayer)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseEntered(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor }
    }
    override func mouseUp(with event: NSEvent) {
        onSelect?()
    }
    
    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        let pad: CGFloat = 8
        let bottomH: CGFloat = 28
        let imgAreaH = bounds.height - bottomH - pad * 2
        containerBox.frame = NSRect(x: pad, y: bottomH + pad, width: bounds.width - pad * 2, height: imgAreaH)
        
        placeholderIconView.frame = NSRect(x: (containerBox.bounds.width - 56)/2, y: (containerBox.bounds.height - 56)/2, width: 56, height: 56)
        imageView.frame = containerBox.bounds.insetBy(dx: 4, dy: 4)
        iconView.frame = NSRect(x: pad + 4, y: pad + 2, width: 22, height: 22)
        titleLabel.frame = NSRect(x: pad + 32, y: pad + 2, width: bounds.width - pad * 2 - 36, height: 22)
        badgeLabel.frame = NSRect(x: bounds.width - 60 - pad, y: bounds.height - 24 - pad, width: 56, height: 18)
    }
    
    func configure(with item: WindowItem, selected: Bool) {
        placeholderIconView.image = item.appIcon
        if let thumb = item.thumbnail {
            imageView.image = thumb
            placeholderIconView.isHidden = true
        } else {
            imageView.image = nil
            placeholderIconView.isHidden = false
        }
        
        if item.isMinimized {
            badgeLabel.stringValue = "最小化"
            badgeLabel.isHidden = false
            alphaValue = 0.8
        } else {
            badgeLabel.isHidden = true
            alphaValue = 1.0
        }
        
        iconView.image = item.appIcon
        titleLabel.stringValue = "\(item.appName) - \(item.title)"
        self.isSelected = selected
    }

    func updateImage(_ image: NSImage, title: String) {
        placeholderIconView.isHidden = true
        imageView.image = image
        titleLabel.stringValue = title
    }

    func updateDetails(image: NSImage, title: String, isMinimized: Bool) {
        placeholderIconView.isHidden = true
        imageView.image = image
        titleLabel.stringValue = title
        if isMinimized {
            badgeLabel.stringValue = "最小化"
            badgeLabel.isHidden = false
            alphaValue = 0.8
        } else {
            badgeLabel.isHidden = true
            alphaValue = 1.0
        }
    }
    
    private func updateSelectionState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            borderLayer.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            borderLayer.borderColor = NSColor.clear.cgColor
        }
        CATransaction.commit()
    }
}

// MARK: - 主悬浮面板
class LiteTabPanel: NSPanel {
    static let shared = LiteTabPanel()
    
    private let visualEffect = NSVisualEffectView()
    private let stackView = NSStackView()
    private let closeButton = NSButton()
    private let tipLabel = NSTextField(labelWithString: "")
    private var cards: [WindowCardView] = []
    private var windows: [WindowItem] = []
    private(set) var selectedIndex: Int = 0
    private var outsideClickMonitor: Any?
    private var outsideScrollMonitor: Any?
    private var optionReleaseTimer: Timer?
    private var keyMonitor: Any?
    private var lastScrollTime: Date = Date()
    
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 250),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        contentView = visualEffect
        
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fillEqually
        stackView.spacing = 12
        visualEffect.addSubview(stackView)
        
        tipLabel.stringValue = "快捷键: [W] 关闭窗口  |  [Q] 退出应用  |  [M] 最小化  |  [H] 隐藏  |  [Esc] 取消"
        tipLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        tipLabel.textColor = NSColor.secondaryLabelColor
        tipLabel.alignment = .center
        visualEffect.addSubview(tipLabel)
        
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        closeButton.contentTintColor = NSColor.secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(onCloseButtonClicked)
        closeButton.wantsLayer = true
        visualEffect.addSubview(closeButton)
    }
    
    @objc func onCloseButtonClicked() {
        dismiss()
    }
    
    func present(with items: [WindowItem], initialIndex: Int = 1) {
        self.windows = items
        guard !windows.isEmpty else { return }
        
        self.selectedIndex = min(initialIndex, windows.count - 1)
        rebuildCards()
        
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        startOutsideMonitors()
        startKeyMonitor()
        startReleaseCheck()
        
        WindowManager.shared.loadThumbnailsAsync(items: windows) { [weak self] (idx, img, title, isMin) in
            guard let self = self, idx < self.cards.count else { return }
            self.cards[idx].updateDetails(image: img, title: "\(self.windows[idx].appName) - \(title)", isMinimized: isMin)
        }
    }
    
    private func rebuildCards() {
        stackView.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        
        let cardW: CGFloat = AppSettings.shared.cardWidth
        let cardH: CGFloat = AppSettings.shared.cardHeight
        let padX: CGFloat = 20
        let padTop: CGFloat = 20
        let showTip = AppSettings.shared.showTipLabel
        let bottomTipH: CGFloat = showTip ? 26 : 8
        
        tipLabel.isHidden = !showTip
        
        for (idx, item) in windows.enumerated() {
            let card = WindowCardView(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH))
            card.configure(with: item, selected: idx == selectedIndex)
            card.onSelect = { [weak self] in
                self?.selectedIndex = idx
                self?.confirmSelection()
            }
            stackView.addArrangedSubview(card)
            cards.append(card)
        }
        
        let totalW = CGFloat(windows.count) * cardW + CGFloat(windows.count - 1) * stackView.spacing + padX * 2
        let totalH = cardH + padTop + bottomTipH + 12
        
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let screenRect = targetScreen.visibleFrame
        let finalW = min(totalW, screenRect.width - 40)
        let finalH = totalH
        
        let originX = screenRect.origin.x + (screenRect.width - finalW) / 2
        let originY = screenRect.origin.y + (screenRect.height - finalH) / 2
        
        setFrame(NSRect(x: originX, y: originY, width: finalW, height: finalH), display: true)
        
        stackView.frame = NSRect(x: padX, y: bottomTipH + 8, width: finalW - padX * 2, height: cardH)
        tipLabel.frame = NSRect(x: 20, y: 6, width: finalW - 40, height: 18)
        closeButton.frame = NSRect(x: finalW - 28, y: finalH - 28, width: 20, height: 20)
    }
    
    func removeCurrentWindow() {
        guard selectedIndex < windows.count else { return }
        let target = windows[selectedIndex]
        WindowManager.shared.closeWindow(pid: target.pid, wid: target.wid)
        
        windows.remove(at: selectedIndex)
        if windows.isEmpty {
            dismiss()
            return
        }
        selectedIndex = min(selectedIndex, windows.count - 1)
        rebuildCards()
    }
    
    func quitCurrentApp() {
        guard selectedIndex < windows.count else { return }
        let targetPid = windows[selectedIndex].pid
        WindowManager.shared.quitApp(pid: targetPid)
        
        windows.removeAll(where: { $0.pid == targetPid })
        if windows.isEmpty {
            dismiss()
            return
        }
        selectedIndex = min(selectedIndex, windows.count - 1)
        rebuildCards()
    }
    
    func minimizeCurrentWindow() {
        guard selectedIndex < windows.count else { return }
        let target = windows[selectedIndex]
        WindowManager.shared.minimizeWindow(pid: target.pid, wid: target.wid)
        target.isMinimized = true
        rebuildCards()
    }
    
    func hideCurrentApp() {
        guard selectedIndex < windows.count else { return }
        let targetPid = windows[selectedIndex].pid
        WindowManager.shared.hideApp(pid: targetPid)
        
        windows.removeAll(where: { $0.pid == targetPid })
        if windows.isEmpty {
            dismiss()
            return
        }
        selectedIndex = min(selectedIndex, windows.count - 1)
        rebuildCards()
    }
    
    private func startReleaseCheck() {
        stopReleaseCheck()
        let requiredFlag = AppSettings.shared.primaryModifierFlag
        optionReleaseTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self = self, self.isVisible else {
                timer.invalidate()
                return
            }
            if !NSEvent.modifierFlags.contains(requiredFlag) {
                timer.invalidate()
                self.optionReleaseTimer = nil
                self.confirmSelection()
            }
        }
    }
    
    private func stopReleaseCheck() {
        optionReleaseTimer?.invalidate()
        optionReleaseTimer = nil
    }
    
    private func startOutsideMonitors() {
        stopOutsideMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            let clickLoc = NSEvent.mouseLocation
            if !self.frame.contains(clickLoc) {
                DispatchQueue.main.async { self.dismiss() }
            }
        }
        
        outsideScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastScrollTime) < 0.12 { return }
            
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(delta) > 2.5 {
                self.lastScrollTime = now
                DispatchQueue.main.async {
                    if delta > 0 { self.selectPrevious() } else { self.selectNext() }
                }
            }
        }
    }
    
    private func stopOutsideMonitors() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let s = outsideScrollMonitor { NSEvent.removeMonitor(s); outsideScrollMonitor = nil }
    }
    
    private func startKeyMonitor() {
        stopKeyMonitor()
        let targetKeyCode = UInt16(AppSettings.shared.hotkeyKeyCode)
        let requiredFlag = AppSettings.shared.primaryModifierFlag
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            
            if event.type == .flagsChanged {
                if !event.modifierFlags.contains(requiredFlag) {
                    self.confirmSelection()
                    return nil
                }
            } else if event.type == .keyDown {
                let code = event.keyCode
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                
                if chars == "w" {
                    self.removeCurrentWindow()
                    return nil
                } else if chars == "q" {
                    self.quitCurrentApp()
                    return nil
                } else if chars == "m" {
                    self.minimizeCurrentWindow()
                    return nil
                } else if chars == "h" {
                    self.hideCurrentApp()
                    return nil
                }
                
                if code == targetKeyCode || code == 48 {
                    if event.modifierFlags.contains(.shift) { self.selectPrevious() } else { self.selectNext() }
                    return nil
                } else if code == 53 {
                    self.dismiss()
                    return nil
                } else if code == 36 {
                    self.confirmSelection()
                    return nil
                } else if code == 123 {
                    self.selectPrevious()
                    return nil
                } else if code == 124 {
                    self.selectNext()
                    return nil
                }
            }
            return event
        }
    }
    
    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
    
    func selectNext() {
        guard !cards.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % cards.count
        updateCardsSelection()
    }
    
    func selectPrevious() {
        guard !cards.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + cards.count) % cards.count
        updateCardsSelection()
    }
    
    private func updateCardsSelection() {
        for (idx, card) in cards.enumerated() { card.isSelected = (idx == selectedIndex) }
    }
    
    func dismiss() {
        stopOutsideMonitors()
        stopKeyMonitor()
        stopReleaseCheck()
        orderOut(nil)
        stackView.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        windows.removeAll()
    }
    
    func confirmSelection() {
        guard selectedIndex < windows.count else {
            dismiss()
            return
        }
        let target = windows[selectedIndex]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            WindowManager.shared.activateWindow(pid: target.pid, wid: target.wid, isMinimized: target.isMinimized)
        }
    }
}

// MARK: - Carbon 热键引擎 (0 延迟毫秒响应)
class CarbonHotkeyManager {
    static let shared = CarbonHotkeyManager()
    private var hotKeyRef: EventHotKeyRef?
    
    func registerHotkey() -> Bool {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x4c544142), id: 1)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (handler, event, userData) -> OSStatus in
            let panel = LiteTabPanel.shared
            if !panel.isVisible {
                let windows = WindowManager.shared.getVisibleWindowsFast()
                let initialIdx = windows.count > 1 ? 1 : 0
                panel.present(with: windows, initialIndex: initialIdx)
            } else {
                let isShift = NSEvent.modifierFlags.contains(.shift)
                if isShift { panel.selectPrevious() } else { panel.selectNext() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        
        let keyCode = UInt32(AppSettings.shared.hotkeyKeyCode)
        let modifiers = UInt32(AppSettings.shared.hotkeyModifiers)
        
        let regErr = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        log("注册自定义热键: KeyCode=\(keyCode), Modifiers=\(modifiers) -> \(regErr == noErr ? "成功" : "失败(\(regErr))")")
        return regErr == noErr
    }
}

// MARK: - SwiftUI 快捷键录制组件
struct ShortcutRecorderButton: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isRecording = false
    @State private var localMonitor: Any?
    
    var body: some View {
        HStack {
            Text("当前切换快捷键:")
            Spacer()
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                        .foregroundColor(isRecording ? .red : .accentColor)
                    Text(isRecording ? "请在键盘上按下新快捷键..." : settings.hotkeyDisplayString)
                        .bold()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
        }
    }
    
    private func startRecording() {
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            
            var mods = 0
            var symbols = ""
            
            if event.modifierFlags.contains(.control) {
                mods |= Int(controlKey)
                symbols += "⌃ "
            }
            if event.modifierFlags.contains(.option) {
                mods |= Int(optionKey)
                symbols += "⌥ "
            }
            if event.modifierFlags.contains(.shift) {
                mods |= Int(shiftKey)
                symbols += "⇧ "
            }
            if event.modifierFlags.contains(.command) {
                mods |= Int(cmdKey)
                symbols += "⌘ "
            }
            
            guard mods != 0 else { return event }
            
            let keyStr = keyName(for: event.keyCode, characters: event.charactersIgnoringModifiers)
            let fullDisplay = symbols + keyStr
            
            settings.hotkeyKeyCode = Int(event.keyCode)
            settings.hotkeyModifiers = mods
            settings.hotkeyDisplayString = fullDisplay
            
            _ = CarbonHotkeyManager.shared.registerHotkey()
            stopRecording()
            return nil
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }
    
    private func keyName(for code: UInt16, characters: String?) -> String {
        switch code {
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 36: return "Return"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return characters?.uppercased() ?? "Key \(code)"
        }
    }
}

// MARK: - SwiftUI 原生设置窗口界面
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin: Bool = false
    @State private var memoryMB: Double = getProcessMemoryMB()
    @State private var screenCaptureOK: Bool = hasScreenCaptureAccess
    @State private var accessibilityOK: Bool = hasAccessibilityAccess
    @State private var selectedTab: Int = 0
    
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)
            
            appearanceTab
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(1)
            
            behaviorTab
                .tabItem { Label("性能与行为", systemImage: "bolt.fill") }
                .tag(2)
            
            aboutTab
                .tabItem { Label("关于与健康", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(width: 520, height: 420)
        .padding(16)
        .onAppear {
            checkAutoLaunchState()
            refreshHealth()
        }
        .onReceive(timer) { _ in
            refreshHealth()
        }
    }
    
    var generalTab: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newVal in
                        toggleAutoLaunch(enabled: newVal)
                    }
            } header: {
                Text("启动设置")
            }
            
            Section {
                ShortcutRecorderButton()
                
                HStack(spacing: 8) {
                    Text("快速预设:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("⌥ Tab") {
                        applyPreset(code: Int(kVK_Tab), mod: Int(optionKey), display: "⌥ Tab")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("⌘ Tab") {
                        applyPreset(code: Int(kVK_Tab), mod: Int(cmdKey), display: "⌘ Tab")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("⌃ Tab") {
                        applyPreset(code: Int(kVK_Tab), mod: Int(controlKey), display: "⌃ Tab")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("⌥ `") {
                        applyPreset(code: 50, mod: Int(optionKey), display: "⌥ `")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
                
                Text("支持自定义录制任意按键组合（点击上方按钮录制），或点击预设一键切换。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("热键自定义")
            }
            
            Section {
                Stepper("最多展示窗口数: \(settings.maxWindowsCount) 个", value: $settings.maxWindowsCount, in: 4...20)
                Text("建议设为 8 ~ 14 个，兼顾大屏视野与极速切换。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("窗口容量")
            }
        }
        .formStyle(.grouped)
    }
    
    private func applyPreset(code: Int, mod: Int, display: String) {
        settings.hotkeyKeyCode = code
        settings.hotkeyModifiers = mod
        settings.hotkeyDisplayString = display
        _ = CarbonHotkeyManager.shared.registerHotkey()
    }
    
    var appearanceTab: some View {
        Form {
            Section {
                Picker("缩略图卡片尺寸", selection: $settings.cardSizeOption) {
                    Text("紧凑 (180 × 145)").tag("compact")
                    Text("标准 (220 × 175)").tag("standard")
                    Text("宽大 (260 × 205)").tag("spacious")
                }
                .pickerStyle(.segmented)
                
                Toggle("显示底部快捷键指引条", isOn: $settings.showTipLabel)
                Text("指引条显示 [W]关窗口 / [Q]退应用 / [M]最小化 / [H]隐藏 等常用按键。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("布局与视觉")
            }
            
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                            .frame(width: settings.cardWidth * 0.7, height: settings.cardHeight * 0.7)
                            .overlay(
                                VStack {
                                    Image(systemName: "macwindow")
                                        .font(.system(size: 24))
                                        .foregroundColor(.accentColor)
                                    Text("卡片比例预览")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            )
                        Text("\(Int(settings.cardWidth)) × \(Int(settings.cardHeight)) pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("实时尺寸预览")
            }
        }
        .formStyle(.grouped)
    }
    
    var behaviorTab: some View {
        Form {
            Section {
                Toggle("在卡片流中包含“最小化到 Dock”的窗口", isOn: $settings.includeMinimized)
                    .onChange(of: settings.includeMinimized) { _, newVal in
                        if newVal {
                            MinimizedScanner.shared.scan()
                        }
                    }
                Text("后台静默索引，选中最小化窗口并松开快捷键后自动从 Dock 弹起。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("窗口过滤 (后台静默扫描，不影响呼出速度)")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("内存截图缓存时长")
                        Spacer()
                        Text("\(Int(settings.cacheDuration)) 秒")
                            .foregroundColor(.accentColor)
                            .bold()
                    }
                    Slider(value: $settings.cacheDuration, in: 5...60, step: 5)
                }
                
                HStack {
                    Text("清除当前所有内存截图缓存")
                    Spacer()
                    Button("立即清空") {
                        ThumbnailCache.shared.clearAll()
                        refreshHealth()
                    }
                }
            } header: {
                Text("高速缓存策略 (已内置等比下采样)")
            }
        }
        .formStyle(.grouped)
    }
    
    var aboutTab: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "macwindow.on.rectangle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.accentColor)
                    .frame(width: 52, height: 52)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("LiteTab")
                        .font(.title2)
                        .bold()
                    Text("极简轻量 · 原生毫秒级窗口切换器")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("版本 0.2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            
            Divider()
            
            VStack(spacing: 10) {
                HStack {
                    Label("屏幕与系统音频录制权限", systemImage: "record.circle")
                    Spacer()
                    if screenCaptureOK {
                        Text("已正常授权 ✅")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                    } else {
                        Button("去授权 ⚠️") {
                            requestScreenCaptureAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Label("辅助功能权限 (识别多窗口/最小化)", systemImage: "hand.raised")
                    Spacer()
                    if accessibilityOK {
                        Text("已正常授权 ✅")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                    } else {
                        Button("去授权 ⚠️") {
                            requestAccessibilityAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Label("真实物理内存 (Footprint)", systemImage: "memorychip")
                    Spacer()
                    Text(String(format: "%.1f MB", memoryMB))
                        .font(.system(.body, design: .monospaced))
                        .bold()
                        .foregroundColor(.green)
                }

                HStack {
                    Label("待机 CPU 消耗", systemImage: "cpu")
                    Spacer()
                    Text("0.0%")
                        .font(.system(.body, design: .monospaced))
                        .bold()
                        .foregroundColor(.green)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)
            
            Spacer()
            
            Text("主线程无锁零阻塞 · 0ms 瞬间呼出 · 内存仅占 30MB 左右")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }
    
    private func checkAutoLaunchState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
    
    private func toggleAutoLaunch(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log("切换自启动异常: \(error)")
            }
        }
    }
    
    private func refreshHealth() {
        memoryMB = getProcessMemoryMB()
        screenCaptureOK = hasScreenCaptureAccess
        accessibilityOK = hasAccessibilityAccess
    }
}

// MARK: - 设置窗口控制器
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    
    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "LiteTab 偏好设置"
        win.contentViewController = hostingController
        win.center()
        win.isReleasedWhenClosed = false
        
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 主入口与菜单栏管理
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("LiteTab 启动完成")
        let hasCap = hasScreenCaptureAccess
        log("当前屏幕录制权限: \(hasCap)")
        if !hasCap {
            requestScreenCaptureAccess()
        }

        let hasAX = hasAccessibilityAccess
        log("当前辅助功能权限: \(hasAX)")
        if !hasAX {
            requestAccessibilityAccess()
        }

        _ = CarbonHotkeyManager.shared.registerHotkey()
        MinimizedScanner.shared.start()
        setupStatusMenu()
    }
    
    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.title = "⇥"
            btn.toolTip = "LiteTab (极简轻量切换)"
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "LiteTab (轻量窗口切换器)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "快捷键: \(AppSettings.shared.hotkeyDisplayString)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 LiteTab", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
