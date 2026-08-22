import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// CapsZoom: hold Caps Lock to show 2x zoom overlay, scroll trackpad to pan.

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

final class ZoomState: ObservableObject {
    @Published var active = false
    @Published var offset: CGPoint = .zero
    var screenSize: CGSize = .zero
    let zoom: CGFloat = 2.0
}

final class CaptureEngine {
    static let shared = CaptureEngine()

    func capture(displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
            guard let display else {
                debugLog("capture: no display for id=\(displayID)")
                return nil
            }
            let own = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.makoto.capszoom"
            }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let c = SCStreamConfiguration()
            c.width = display.width
            c.height = display.height
            c.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
            debugLog("capture OK id=\(display.displayID) \(img.width)x\(img.height) exclude=\(own.count)")
            return img
        } catch {
            debugLog("capture error \(error)")
            return nil
        }
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

    override func scrollWheel(with event: NSEvent) {
        guard state.active else { return }
        let screenW = state.screenSize.width
        let screenH = state.screenSize.height
        let dx = CGFloat(event.scrollingDeltaX)
        let dy = CGFloat(event.scrollingDeltaY)
        // 指の動きと同じ方向に映像が動く（従来は逆）
        var ox = state.offset.x - dx
        var oy = state.offset.y + dy
        let maxX = screenW * (state.zoom - 1) / state.zoom
        let maxY = screenH * (state.zoom - 1) / state.zoom
        ox = min(max(ox, 0), maxX)
        oy = min(max(oy, 0), maxY)
        state.offset = CGPoint(x: ox, y: oy)
        needsDisplay = true
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    let state = ZoomState()
    var tap: CFMachPort?
    var panel: NSPanel?
    var zoomView: ScreenZoomView?
    var statusItem: NSStatusItem?

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
        let view = ScreenZoomView(state: state)
        panel.contentView = view
        self.panel = panel
        self.zoomView = view

        startTap()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🔍"
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit CapsZoom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.statusItem = item
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
        let capsOn = event.flags.contains(.maskAlphaShift)
        if Thread.isMainThread {
            setActive(capsOn)
        } else {
            DispatchQueue.main.async { self.setActive(capsOn) }
        }
        return Unmanaged.passRetained(event)
    }

    func setActive(_ on: Bool) {
        guard on != state.active else { return }
        state.active = on
        if on {
            let loc = NSEvent.mouseLocation
            let screen = screenContaining(loc)
            let frame = screen.frame
            state.screenSize = frame.size
            // その画面内のローカル座標（下左原点）
            let mx = max(0, min(loc.x - frame.minX, frame.width))
            let my = max(0, min(loc.y - frame.minY, frame.height))
            // 拡大前にカーソル下にあった点が、拡大後も同じ画面位置に来る
            // displayed = z * (p - offset) = p  ⇒  offset = p * (1 - 1/z)
            let z = state.zoom
            let ox = mx * (z - 1) / z
            let oy = my * (z - 1) / z
            state.offset = CGPoint(x: ox, y: oy)
            let did = cgDisplayID(of: screen)
            debugLog("activate screen=\(Int(frame.width))x\(Int(frame.height)) mouse=(\(Int(mx)),\(Int(my))) off=(\(Int(ox)),\(Int(oy))) did=\(did)")
            panel?.setFrame(frame, display: false)
            Task { [weak self] in
                let img = await CaptureEngine.shared.capture(displayID: did)
                await MainActor.run { [weak self] in
                    guard let self, self.state.active else { return }
                    if let img {
                        self.zoomView?.image = img
                    } else {
                        debugLog("snapshot nil")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel?.orderFrontRegardless()
                }
            }
        } else {
            panel?.orderOut(nil)
            zoomView?.image = nil
        }
    }
}
