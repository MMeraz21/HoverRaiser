import Cocoa
import ApplicationServices
import os

@MainActor
class HoverRaiser {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Delay before raising (in seconds) - prevents accidental raises at monitor edges
    private let raiseDelay: TimeInterval = 0.1
    private var raiseTimer: Timer?
    private var pendingScreen: NSScreen?
    
    // Throttling to prevent performance issues (nonisolated for access from callback)
    private nonisolated(unsafe) var lastProcessedTime: CFAbsoluteTime = 0
    private let throttleInterval: CFAbsoluteTime = 0.05  // Process at most every 50ms
    
    // Track which monitor the mouse is on (for monitor-change detection)
    private nonisolated(unsafe) var lastMonitorHash: Int = 0
    
    init() {
        checkAccessibilityPermissions()
    }
    
    private func checkAccessibilityPermissions() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue!] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            print("⚠️  Accessibility access required!")
            print("   Please enable HoverRaiser in:")
            print("   System Settings → Privacy & Security → Accessibility")
            print("")
            print("   Restart the app after granting permission.")
        } else {
            print("✓ Accessibility access granted")
        }
    }
    
    func start() {
        print("🚀 HoverRaiser started")
        print("   • Cross to a different monitor → raises topmost window on that monitor")
        print("   • Same monitor → click to raise (normal macOS behavior)")
        print("   Press Ctrl+C to quit")
        
        // Initialize last monitor to current mouse location
        let initialLocation = NSEvent.mouseLocation
        if let screen = getScreenContaining(point: initialLocation) {
            lastMonitorHash = screen.hash
        }
        
        // Create event tap for mouse moved events
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let instance = Unmanaged<HoverRaiser>.fromOpaque(refcon).takeUnretainedValue()
                instance.handleMouseMoved(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )
        
        guard let eventTap = eventTap else {
            print("❌ Failed to create event tap. Make sure accessibility is enabled.")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        CFRunLoopRun()
    }
    
    private nonisolated func getScreenContaining(point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.screens.first
    }
    
    private nonisolated func convertToScreenCoordinates(_ cgPoint: CGPoint) -> NSPoint {
        guard let mainScreen = NSScreen.screens.first else {
            return NSPoint(x: cgPoint.x, y: cgPoint.y)
        }
        let screenHeight = mainScreen.frame.height
        return NSPoint(x: cgPoint.x, y: screenHeight - cgPoint.y)
    }
    
    private nonisolated func handleMouseMoved(event: CGEvent) {
        // Throttle
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessedTime >= throttleInterval else { return }
        lastProcessedTime = now
        
        let cgLocation = event.location
        let screenLocation = convertToScreenCoordinates(cgLocation)
        
        // Get current monitor
        guard let currentScreen = getScreenContaining(point: screenLocation) else { return }
        let currentMonitorHash = currentScreen.hash
        
        // Check if we've changed monitors
        let monitorChanged = (currentMonitorHash != lastMonitorHash) && (lastMonitorHash != 0)
        lastMonitorHash = currentMonitorHash
        
        guard monitorChanged else { return }
        
        // Dispatch to main thread - raise the topmost window on the new screen
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRaise(for: currentScreen)
        }
    }
    
    private func scheduleRaise(for screen: NSScreen) {
        raiseTimer?.invalidate()
        pendingScreen = screen
        
        raiseTimer = Timer.scheduledTimer(withTimeInterval: raiseDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performRaise()
            }
        }
    }
    
    private func cancelPendingRaise() {
        raiseTimer?.invalidate()
        raiseTimer = nil
        pendingScreen = nil
    }
    
    private func performRaise() {
        guard let screen = pendingScreen else { return }
        
        // Find the topmost window on this screen
        guard let (window, pid) = getTopmostWindowOnScreen(screen) else {
            pendingScreen = nil
            return
        }
        
        // Raise the window
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        
        // Activate the app if it's different from frontmost
        if let app = NSRunningApplication(processIdentifier: pid),
           let frontmost = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != frontmost.processIdentifier {
            app.activate()
        }
        
        pendingScreen = nil
    }
    
    /// Find the topmost (frontmost) window that's primarily on the given screen
    private func getTopmostWindowOnScreen(_ targetScreen: NSScreen) -> (AXUIElement, pid_t)? {
        // Get all on-screen windows, ordered front-to-back
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        let targetFrame = targetScreen.frame
        let myPID = getpid()
        
        for windowInfo in windowList {
            // Skip windows without bounds
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }
            
            // Skip tiny windows (likely system UI)
            guard width > 50 && height > 50 else { continue }
            
            let windowFrame = CGRect(x: x, y: y, width: width, height: height)
            
            // Check if window center is on target screen (using CG coordinates)
            let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            
            // Convert target screen frame to CG coordinates (flip Y)
            guard let mainScreen = NSScreen.screens.first else { continue }
            let mainHeight = mainScreen.frame.height
            let targetCGFrame = CGRect(
                x: targetFrame.origin.x,
                y: mainHeight - targetFrame.origin.y - targetFrame.height,
                width: targetFrame.width,
                height: targetFrame.height
            )
            
            guard targetCGFrame.contains(windowCenter) else { continue }
            
            // Get the PID
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }
            
            // Skip our own windows
            guard pid != myPID else { continue }
            
            // Skip certain system processes
            if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
                let skipApps = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center"]
                if skipApps.contains(ownerName) { continue }
            }
            
            // Get the window's layer - skip if it's not a normal window layer
            if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            
            // Found a good window - now get its AXUIElement
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            
            guard result == .success,
                  let windows = windowsRef as? [AXUIElement],
                  !windows.isEmpty else {
                continue
            }
            
            // Try to find the matching window by position
            for axWindow in windows {
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                
                if let positionRef = positionRef, let sizeRef = sizeRef {
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                    
                    // Check if this AX window matches the CG window (approximately)
                    if abs(position.x - windowFrame.origin.x) < 5 &&
                       abs(position.y - windowFrame.origin.y) < 5 {
                        return (axWindow, pid)
                    }
                }
            }
            
            // If we couldn't match by position, just return the first window
            return (windows[0], pid)
        }
        
        return nil
    }
    
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
        print("\n👋 HoverRaiser stopped")
    }
}

// Handle Ctrl+C gracefully
signal(SIGINT) { _ in
    print("\nReceived interrupt signal...")
    CFRunLoopStop(CFRunLoopGetMain())
    exit(0)
}

// Main entry point
let hoverRaiser = HoverRaiser()
hoverRaiser.start()
