import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import IOKit
import ServiceManagement
import ScreenCaptureKit

// CapsZoom: Caps Lock toggles live 2x zoom that follows the cursor (WinZoom-style).

func debugLog(_ s: String) {
    NSLog("CapsZoom: \(s)")
    let path = "/Users/makoto/ai/capszoom/debug.log"
    let line = "\(Date()) \(s)\n"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    }
}

func screenContaining(_ p: NSPoint) -> NSScreen {
    NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens[0]
}

func cgDisplayID(of screen: NSScreen) -> CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return CGDirectDisplayID((screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0)
}

// CGEvent を捨てても CapsLock のロック状態は HID 側で残る。
@_silgen_name("IOHIDSetModifierLockState")
func IOHIDSetModifierLockState(_ handle: io_connect_t, _ selector: Int32, _ state: Bool) -> kern_return_t

func forceCapsLockOff() {
    guard let matching = IOServiceMatching("IOHIDSystem") else { return }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 1, &connect) == KERN_SUCCESS else { return }
    defer { IOServiceClose(connect) }
    _ = IOHIDSetModifierLockState(connect, 1, false) // kIOHIDCapsLockState
}

final class ZoomState {
    var active = false
    var offset: CGPoint = .zero
    var screenSize: CGSize = .zero
    let zoom: CGFloat = 2.0
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = CaptureEngine()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var stream: SCStream?
    private var runningDisplay: CGDirectDisplayID = 0
    private var startGen = 0
    var onFrame: ((CGImage) -> Void)?

    func start(displayID: CGDirectDisplayID) {
        if stream != nil && runningDisplay == displayID { return }
        startGen += 1
        let gen = startGen
        Task { await restart(displayID: displayID, gen: gen) }
    }

    func stop() {
        startGen += 1
        let s = stream
        stream = nil
        runningDisplay = 0
        Task {
            if let s { try? await s.stopCapture() }
        }
    }

    private func restart(displayID: CGDirectDisplayID, gen: Int) async {
        if let old = stream {
            try? await old.stopCapture()
            if gen != startGen { return }
            stream = nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if gen != startGen { return }
            let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
            guard let display else {
                debugLog("stream: no display for id=\(displayID)")
                return
            }
            // 窓リストはパネル非表示だと空になる。アプリごと除外しないと
            // 表示後のオーバーレイを撮って 2x が再帰する。
            let ownApps = content.applications.filter {
                $0.bundleIdentifier == "com.makoto.capszoom"
            }
            let ownWins = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.makoto.capszoom"
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let scale = NSScreen.screens.first {
                cgDisplayID(of: $0) == display.displayID
            }?.backingScaleFactor ?? 2.0
            let c = SCStreamConfiguration()
            c.width = Int((CGFloat(display.width) * scale).rounded())
            c.height = Int((CGFloat(display.height) * scale).rounded())
            c.showsCursor = false
            c.captureResolution = .best
            c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            c.queueDepth = 3
            let s = SCStream(filter: filter, configuration: c, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capszoom.stream"))
            try await s.startCapture()
            if gen != startGen {
                try? await s.stopCapture()
                return
            }
            stream = s
            runningDisplay = display.displayID
            debugLog("stream start id=\(display.displayID) \(c.width)x\(c.height) excludeApps=\(ownApps.count) excludeWins=\(ownWins.count)")
        } catch {
            debugLog("stream error \(error)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sampleBuffer.imageBuffer else { return }
        let ciImg = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(ciImg, from: ciImg.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(cg)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("stream stopped \(error)")
    }
}

final class ScreenZoomView: NSView {
    let state: ZoomState
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    init(state: ZoomState) {
        self.state = state
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgctx = NSGraphicsContext.current?.cgContext, let img = image else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }
        let screenW = state.screenSize.width > 0 ? state.screenSize.width : bounds.width
        let screenH = state.screenSize.height > 0 ? state.screenSize.height : bounds.height
        cgctx.setFillColor(CGColor(gray: 0, alpha: 1))
        cgctx.fill(bounds)
        cgctx.saveGState()
        cgctx.scaleBy(x: state.zoom, y: state.zoom)
        cgctx.translateBy(x: -state.offset.x, y: -state.offset.y)
        cgctx.draw(img, in: CGRect(x: 0, y: 0, width: screenW, height: screenH))
        cgctx.restoreGState()
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!
    let state = ZoomState()
    var tap: CFMachPort?
    var panel: NSPanel?
    var zoomView: ScreenZoomView?
    var statusItem: NSStatusItem?
    var loginMenuItem: NSMenuItem?
    var followTimer: Timer?
    var lastDisplayID: CGDirectDisplayID = 0

    var lastCapsMs: TimeInterval = 0
    let capsDebounce: TimeInterval = 0.2
    let capsKeycode: Int64 = 57 // kVK_CapsLock
    var droppingCapsUnlock = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            debugLog("accessibility permission requested (AXTrusted=false)")
        }
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!.frame
        let panel = NSPanel(contentRect: screen,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let view = ScreenZoomView(state: state)
        panel.contentView = view
        self.panel = panel
        self.zoomView = view

        CaptureEngine.shared.onFrame = { [weak self] img in
            guard let self, self.state.active else { return }
            self.zoomView?.image = img
            if self.panel?.isVisible != true {
                NSApp.activate(ignoringOtherApps: true)
                self.panel?.orderFrontRegardless()
            }
        }

        startTap()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🔍"
        let menu = NSMenu()
        menu.delegate = self
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CapsZoom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.statusItem = item
        self.loginMenuItem = login
        refreshLoginItemState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        followTimer?.invalidate()
        CaptureEngine.shared.stop()
    }

    func startTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                                              return AppDelegate.shared.handle(type: type, event: event)
                                          }, userInfo: nil) else {
            let acc = AXIsProcessTrusted()
            debugLog("failed to create event tap (AXTrusted=\(acc))")
            return
        }
        debugLog("event tap created OK")
        self.tap = tap
        let rl = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passRetained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == capsKeycode {
            let pass = event.flags.contains(.maskShift)
                || event.flags.contains(.maskControl)
                || event.flags.contains(.maskAlternate)
                || event.flags.contains(.maskCommand)
            if pass {
                return Unmanaged.passRetained(event)
            }
            if !droppingCapsUnlock && (type == .flagsChanged || type == .keyDown) {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastCapsMs >= capsDebounce {
                    lastCapsMs = now
                    if Thread.isMainThread {
                        setActive(!state.active)
                    } else {
                        DispatchQueue.main.async { self.setActive(!self.state.active) }
                    }
                }
            }
            droppingCapsUnlock = true
            forceCapsLockOff()
            DispatchQueue.main.async { self.droppingCapsUnlock = false }
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    func setActive(_ on: Bool) {
        guard on != state.active else { return }
        state.active = on
        if on {
            applyFollow()
            followTimer?.invalidate()
            followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.applyFollow()
            }
            if let t = followTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        } else {
            followTimer?.invalidate()
            followTimer = nil
            CaptureEngine.shared.stop()
            lastDisplayID = 0
            panel?.orderOut(nil)
            zoomView?.image = nil
        }
    }

    /// カーソル直下の点が画面上の同じ位置に残るよう offset を更新し、画面が変わったらストリームを付け替える。
    func applyFollow() {
        guard state.active else { return }
        let loc = NSEvent.mouseLocation
        let screen = screenContaining(loc)
        let frame = screen.frame
        state.screenSize = frame.size
        let mx = max(0, min(loc.x - frame.minX, frame.width))
        let my = max(0, min(loc.y - frame.minY, frame.height))
        let z = state.zoom
        state.offset = CGPoint(x: mx * (z - 1) / z, y: my * (z - 1) / z)
        zoomView?.needsDisplay = true
        let did = cgDisplayID(of: screen)
        if panel?.frame != frame {
            panel?.setFrame(frame, display: false)
        }
        if did != lastDisplayID {
            lastDisplayID = did
            debugLog("follow screen=\(Int(frame.width))x\(Int(frame.height)) did=\(did)")
            CaptureEngine.shared.start(displayID: did)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLoginItemState()
    }

    func refreshLoginItemState() {
        let on = SMAppService.mainApp.status == .enabled
        loginMenuItem?.state = on ? .on : .off
    }

    @objc func toggleLoginItem(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                debugLog("login item off")
            } else {
                try SMAppService.mainApp.register()
                debugLog("login item on")
            }
        } catch {
            debugLog("login item error \(error)")
        }
        refreshLoginItemState()
    }
}
