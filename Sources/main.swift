import Cocoa
import ApplicationServices
import os

@MainActor
class HoverRaiser {
    private var lastRaisedWindow: AXUIElement?
    private var lastRaisedPID: pid_t = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Delay before raising (in seconds) - prevents accidental raises
    private let raiseDelay: TimeInterval = 0.15
    private var raiseTimer: Timer?
    private var pendingWindow: AXUIElement?
    private var pendingPID: pid_t = 0
    
    // Throttling to prevent performance issues (nonisolated for access from callback)
    private nonisolated(unsafe) var lastProcessedTime: CFAbsoluteTime = 0
    private let throttleInterval: CFAbsoluteTime = 0.05  // Process at most every 50ms
    
    init() {
        checkAccessibilityPermissions()
    }
    
    private func checkAccessibilityPermissions() {
        // Use the raw string key to avoid Swift 6 concurrency issues with the global constant
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
        print("🚀 HoverRaiser started - hover over windows to raise them")
        print("   Press Ctrl+C to quit")
        
        // Create event tap for mouse moved events
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        
        // Store self in a way we can access from the callback
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
        
        // Run the event loop
        CFRunLoopRun()
    }
    
    private nonisolated func handleMouseMoved(event: CGEvent) {
        // Throttle: skip if we processed too recently
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessedTime >= throttleInterval else { return }
        lastProcessedTime = now
        
        let mouseLocation = event.location
        
        // Find the window under the cursor (do this on the callback thread to reduce main thread work)
        guard let (window, pid) = getWindowAtPoint(mouseLocation) else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingRaise()
            }
            return
        }
        
        // Dispatch to main thread for UI work
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Don't re-raise the same window
            if let lastWindow = self.lastRaisedWindow,
               CFEqual(window, lastWindow),
               pid == self.lastRaisedPID {
                self.cancelPendingRaise()
                return
            }
            
            // Schedule a delayed raise (prevents flickering when moving quickly)
            self.scheduleRaise(window: window, pid: pid)
        }
    }
    
    private func scheduleRaise(window: AXUIElement, pid: pid_t) {
        // Cancel any pending raise
        raiseTimer?.invalidate()
        
        pendingWindow = window
        pendingPID = pid
        
        raiseTimer = Timer.scheduledTimer(withTimeInterval: raiseDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performRaise()
            }
        }
    }
    
    private func cancelPendingRaise() {
        raiseTimer?.invalidate()
        raiseTimer = nil
        pendingWindow = nil
        pendingPID = 0
    }
    
    private func performRaise() {
        guard let window = pendingWindow else { return }
        
        // Raise the window (brings to front)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        
        // Activate the app to give it keyboard focus
        if let app = NSRunningApplication(processIdentifier: pendingPID) {
            app.activate()
        }
        
        lastRaisedWindow = window
        lastRaisedPID = pendingPID
        
        pendingWindow = nil
        pendingPID = 0
    }
    
    private nonisolated func getWindowAtPoint(_ point: CGPoint) -> (AXUIElement, pid_t)? {
        // Get the element at the mouse position
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        
        guard result == .success, let element = element else {
            return nil
        }
        
        // Get the window containing this element
        var window: AXUIElement?
        var currentElement: AXUIElement? = element
        
        while let current = currentElement {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            
            if let roleStr = role as? String, roleStr == kAXWindowRole as String {
                window = current
                break
            }
            
            var parent: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            
            if parentResult == .success, CFGetTypeID(parent!) == AXUIElementGetTypeID() {
                currentElement = (parent as! AXUIElement)
            } else {
                break
            }
        }
        
        guard let foundWindow = window else {
            return nil
        }
        
        // Get the PID
        var pid: pid_t = 0
        AXUIElementGetPid(foundWindow, &pid)
        
        // Don't raise our own process or the system UI
        if pid == getpid() || pid == 0 {
            return nil
        }
        
        return (foundWindow, pid)
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
