//
//  VoxportApp.swift
//  Voxport
//
//  Created by Bastian Wölfle on 19.08.25.
//
import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import QuartzCore
import Carbon.HIToolbox // For keyboard shortcut handling
import ApplicationServices // For accessibility APIs
import os.log

// Create a logger instance for debugging
private let logger = Logger(subsystem: "io.schlingel.Voxport", category: "Accessibility")

// MARK: - System volume control via CoreAudio
final class SystemAudio: ObservableObject {
    @Published var volume: Float = 0 // 0.0 - 1.0 (OUTPUT)
    @Published var isMuted: Bool = false
    @Published var inputVolume: Float = 0 // 0.0 - 1.0 (INPUT)
    @Published var isInputMuted: Bool = false

    private var volumeListenerAddresses: [AudioObjectPropertyAddress] = []
    private var isObserving = false
    var onInputVolumeChanged: (() -> Void)?
    var onInputMuteChanged: (() -> Void)?

    // Default OUTPUT device
    private var outputDeviceID: AudioObjectID {
        var id = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    // Default INPUT device
    private var inputDeviceID: AudioObjectID {
        var id = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    func refresh() {
        self.volume = getOutputVolume()
        self.isMuted = getOutputMute()
        self.inputVolume = getInputVolume()
        self.isInputMuted = getInputMute()
    }

    // OUTPUT volume APIs
    func setVolume(_ v: Float) {
        var vol = max(0, min(1, v))
        setProperty(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput, device: outputDeviceID, data: &vol)
        self.volume = vol
        if vol > 0 && isMuted { setOutputMute(false) }
    }

    func toggleMute() { setOutputMute(!isMuted) }

    private func setOutputMute(_ mute: Bool) {
        var m: UInt32 = mute ? 1 : 0
        setProperty(selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, device: outputDeviceID, data: &m)
        self.isMuted = mute
    }

    private func getOutputVolume() -> Float {
        var v = Float(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(outputDeviceID, &addr, 0, nil, &size, &v)
        return status == noErr ? v : 0
    }

    private func getOutputMute() -> Bool {
        var m: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(outputDeviceID, &addr, 0, nil, &size, &m)
        return status == noErr ? (m != 0) : false
    }

    // MARK: - Input channel helpers
    private func hasProperty(_ device: AudioObjectID,
                             selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope,
                             element: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectHasProperty(device, &addr)
    }
    
    private func getInputMute() -> Bool {
        guard inputDeviceID != kAudioObjectUnknown else { return false }
        var mute: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(inputDeviceID, &addr, 0, nil, &size, &mute)
        return status == noErr && mute == 1
    }

    func setInputMute(_ mute: Bool) {
        guard inputDeviceID != kAudioObjectUnknown else { return }
        var muteVal: UInt32 = mute ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(inputDeviceID, &addr, 0, nil, size, &muteVal)
        self.isInputMuted = mute
    }

    private func inputVolumeElements() -> [UInt32] {
        // Prefer master element if available; otherwise fall back to per-channel elements 1..32
        if hasProperty(inputDeviceID,
                       selector: kAudioDevicePropertyVolumeScalar,
                       scope: kAudioDevicePropertyScopeInput,
                       element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        var elems: [UInt32] = []
        // Probe a reasonable channel range; most devices expose <= 8, but we allow up to 32
        for ch: UInt32 in 1...32 {
            if hasProperty(inputDeviceID,
                           selector: kAudioDevicePropertyVolumeScalar,
                           scope: kAudioDevicePropertyScopeInput,
                           element: ch) {
                elems.append(ch)
            }
        }
        return elems
    }

    private func getInputVolume() -> Float {
        let elems = inputVolumeElements()
        guard !elems.isEmpty else { return 0 }
        var sum: Float = 0
        var count: Float = 0
        for elem in elems {
            var v = Float(0)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: elem
            )
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(inputDeviceID, &addr, 0, nil, &size, &v)
            if status == noErr {
                sum += v
                count += 1
            }
        }
        return count > 0 ? (sum / count) : 0
    }

    func setInputVolumeScalar(_ v: Float) {
        let vol = max(0, min(1, v))
        let elems = inputVolumeElements()
        guard !elems.isEmpty else { return }
        for elem in elems {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: elem
            )
            var value = vol
            let size = UInt32(MemoryLayout<Float>.size)
            _ = AudioObjectSetPropertyData(inputDeviceID, &addr, 0, nil, size, &value)
        }
        self.inputVolume = vol
    }

    func startObservingInputVolumeChanges() {
        guard !isObserving else { return }
        isObserving = true
        registerInputDeviceListeners()
    }

    private func registerInputDeviceListeners() {
        // Listen for default input device changes
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, .main) { [weak self] _, _ in
            guard let self = self else { return }
            self.refresh()
            self.registerInputVolumeListeners() // Re-register for new device
            self.onInputVolumeChanged?()
            self.onInputMuteChanged?()
        }
        registerInputVolumeListeners()
    }

    private func registerInputVolumeListeners() {
        // Remove old references (listeners are not explicitly removed here for brevity)
        volumeListenerAddresses.removeAll()
        let id = inputDeviceID
        guard id != kAudioObjectUnknown else { return }

        // Listener for Mute
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, .main) { [weak self] _, _ in
            guard let self = self else { return }
            self.isInputMuted = self.getInputMute()
            self.onInputMuteChanged?()
        }

        // Listeners for Volume
        let elements = inputVolumeElements()
        for elem in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: elem
            )
            volumeListenerAddresses.append(addr)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main) { [weak self] _, _ in
                guard let self = self else { return }
                self.inputVolume = self.getInputVolume()
                self.onInputVolumeChanged?()
            }
        }
    }

    // INPUT volume APIs
    func setInputVolumePercent(_ percent: Int) {
        let p = max(0, min(100, percent))
        setInputVolumeScalar(Float(p) / 100.0)
    }

    func changeInputVolumeBy(_ delta: Int) {
        let current = getInputVolume()
        let newScalar = max(0, min(1, current + Float(delta) / 100.0))
        setInputVolumeScalar(newScalar)
    }

    // Generic setter
    private func setProperty<T>(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, device: AudioObjectID, data: inout T) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<T>.size) // value parameter for SetProperty, not inout
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &data)
    }
}

// MARK: - Entry point
@main
struct VoxportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Keyboard shortcut manager
final class KeyboardShortcutManager: ObservableObject {
    @Published var shortcut: KeyShortcut? = nil
    @Published var isRecording = false
    @Published var recordedShortcut: KeyShortcut? = nil
    
    private var monitor: Any?
    private var previousInputVolume: Float = 0.0
    
    struct KeyShortcut: Codable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        
        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
        
        var isFunctionKey: Bool {
            let functionKeyCodes: Set<UInt32> = [105, 107, 113, 106, 64, 79, 80, 90, 114, 115, 116, 117, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            return functionKeyCodes.contains(keyCode)
        }
        
        var displayString: String {
            var parts: [String] = []
            
            if modifiers & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 {
                parts.append("⌃")
            }
            if modifiers & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 {
                parts.append("⌥")
            }
            if modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 {
                parts.append("⇧")
            }
            if modifiers & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 {
                parts.append("⌘")
            }
            
            if let key = NSEvent.KeyCarbbonKeyCodeToString(keyCode) {
                // If shift is pressed and it's a letter, make it uppercase
                if modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 && key.count == 1 && key.first?.isLetter == true {
                    parts.append(key.uppercased())
                } else {
                    parts.append(key)
                }
            }
            
            return parts.joined()
        }
    }
    
    func saveShortcut(_ shortcut: KeyShortcut) {
        self.shortcut = shortcut
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "KeyboardShortcut")
        }
        // Note: setupGlobalMonitor will be called when audio instance is available
    }
    
    func loadShortcut(audio: SystemAudio) {
        print("🔍 DEBUG: Loading shortcut from UserDefaults...")
        NSLog("🔍 DEBUG: Loading shortcut from UserDefaults...")
        logger.debug("Loading shortcut from UserDefaults...")
        print("🔍 DEBUG: About to check UserDefaults for KeyboardShortcut data...")
        NSLog("🔍 DEBUG: About to check UserDefaults for KeyboardShortcut data...")
        if let data = UserDefaults.standard.data(forKey: "KeyboardShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyShortcut.self, from: data) {
            print("✅ DEBUG: Loaded shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
            NSLog("✅ DEBUG: Loaded shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
            logger.debug("Loaded shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
            self.shortcut = shortcut
            setupGlobalMonitor(audio: audio)
        } else {
            print("❌ DEBUG: No shortcut found in UserDefaults")
            NSLog("❌ DEBUG: No shortcut found in UserDefaults")
            logger.debug("No shortcut found in UserDefaults")
        }
    }
    
    func removeShortcut() {
        shortcut = nil
        UserDefaults.standard.removeObject(forKey: "KeyboardShortcut")
        removeGlobalMonitor()
    }
    
    func setupGlobalMonitor(audio: SystemAudio) {
        guard let shortcut = shortcut else { 
            print("❌ DEBUG: setupGlobalMonitor called but no shortcut is set")
            NSLog("❌ DEBUG: setupGlobalMonitor called but no shortcut is set")
            return 
        }
        
        removeGlobalMonitor()
        
        print("🔍 DEBUG: Setting up global monitor for shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
        NSLog("🔍 DEBUG: Setting up global monitor for shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
        logger.debug("Setting up global monitor for shortcut: \(shortcut.displayString) (keyCode: \(shortcut.keyCode), modifiers: \(shortcut.modifiers))")
        
        // Monitor both keyDown and flagsChanged events to catch function keys
        print("🔍 DEBUG: Attempting to add global monitor...")
        NSLog("🔍 DEBUG: Attempting to add global monitor...")
        
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return }
            
            let eventModifiers = UInt32(event.modifierFlags.rawValue) & UInt32(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
            
            // Debug logging for all events
            print("🔍 Event: type=\(event.type), keyCode=\(event.keyCode), modifiers=\(eventModifiers), expected=\(shortcut.keyCode), expectedModifiers=\(shortcut.modifiers)")
            
            // Test trigger for space key to verify global monitor is working
            if event.keyCode == 49 { // Space key
                print("🎯 TEST TRIGGER: Space key pressed - testing global monitor functionality")
                self.handleShortcutPress(audio: audio)
                return
            }
            
            // Check if this event matches our shortcut
            let keyCodeMatches = UInt32(event.keyCode) == shortcut.keyCode
            let modifiersMatch = eventModifiers == shortcut.modifiers
            
            if keyCodeMatches && modifiersMatch {
                print("✅ Match found! Checking event type...")
                // For function keys, only trigger on flagsChanged
                // For regular keys, only trigger on keyDown
                if (shortcut.isFunctionKey && event.type == .flagsChanged) || 
                   (!shortcut.isFunctionKey && event.type == .keyDown) {
                    print("🎯 TRIGGERED! Shortcut activated")
                    self.handleShortcutPress(audio: audio)
                } else {
                    print("❌ Event type mismatch. isFunctionKey=\(shortcut.isFunctionKey), eventType=\(event.type)")
                }
            }
        }
        
        print("✅ DEBUG: Global monitor setup completed")
        print("🔍 DEBUG: Global monitor created: \(monitor != nil)")
        NSLog("🔍 DEBUG: Global monitor created: \(monitor != nil)")
        NSLog("✅ DEBUG: Global monitor setup completed")
        
        // Test if global monitor is working by trying to add a local monitor as well
        print("🔍 DEBUG: Testing local monitor for comparison...")
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            print("🔍 LOCAL EVENT: type=\(event.type), keyCode=\(event.keyCode)")
            return event
        }
        print("🔍 DEBUG: Local monitor added: \(localMonitor != nil)")
        NSLog("✅ DEBUG: Global monitor setup completed")
    }
    
    private func removeGlobalMonitor() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
    
    func handleShortcutPress(audio: SystemAudio) {
        // Store current volume before muting
        previousInputVolume = audio.inputVolume
        
        // Toggle mute state
        audio.setInputMute(!audio.isInputMuted)
    }
    
    func restorePreviousVolume(audio: SystemAudio) {
        if previousInputVolume > 0 {
            audio.setInputVolumeScalar(previousInputVolume)
        }
    }
    
    func restorePreviousVolume() {
        if previousInputVolume > 0 {
            SystemAudio().setInputVolumeScalar(previousInputVolume)
        }
    }
}

// MARK: - Global state for HUD visibility
final class VisibilityManager: ObservableObject {
    @Published var isShowing = false
    @Published var isUnmuting = false
    @Published var isInTransition = false
    @Published var displayMutedState = false  // Separate state for what to display
}

// MARK: - App Delegate manages the top-centered panel AND CLI
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audio = SystemAudio()
    let visibility = VisibilityManager()
    private var panelController: NotchPanelController!
    private var statusItem: NSStatusItem!
    private var hideTimer: Timer?
    private var keyboardShortcutManager = KeyboardShortcutManager()
    private var settingsWindow: NSWindow?

    private let mutedSize = NSSize(width: 60, height: 45)
    private let standardSize = NSSize(width: 260, height: 45)

    private lazy var statusMenu: NSMenu = {
        let m = NSMenu()
        let settings = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(settings)
        m.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Voxport", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        return m
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 DEBUG: applicationDidFinishLaunching called - TEST")
        NSLog("🚀 DEBUG: applicationDidFinishLaunching called - TEST")
        logger.debug("applicationDidFinishLaunching called - TEST")
        
        // Keep app as regular app for testing event monitoring
        // NSApp.setActivationPolicy(.accessory)
        
        // Request accessibility permissions for global keyboard shortcuts
        requestAccessibilityPermissions()
        // Status item (left click shows HUD, right click opens menu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voxport")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // --- CLI ---
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--set-input-volume"), i + 1 < args.count, let pct = Int(args[i+1]), (0...100).contains(pct) {
            audio.setInputVolumePercent(pct)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        if let i = args.firstIndex(of: "--change-input-volume"), i + 1 < args.count, let delta = Int(args[i+1]) {
            audio.changeInputVolumeBy(delta)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        // --- /CLI ---

        // UI panel
        panelController = NotchPanelController(
            content: ContentView(),
            audio: audio,
            visibility: visibility
        )

        // Listen for external script commands via Distributed Notification Center
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("Voxport.SetInputVolumePercent"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let pct = note.userInfo?["percent"] as? Int { self.audio.setInputVolumePercent(pct); self.showWithAutoHide() }
        }
        dnc.addObserver(forName: NSNotification.Name("Voxport.ChangeInputVolumeBy"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let delta = note.userInfo?["delta"] as? Int { self.audio.changeInputVolumeBy(delta); self.showWithAutoHide() }
        }

        // When system input volume changes (from anywhere), refresh and show for 5s
        audio.onInputVolumeChanged = { [weak self] in
            self?.audio.refresh()
            guard let self = self else { return }
            
            // If we're muted, show the mute panel
            if self.audio.isInputMuted {
                self.showVolumeWhileMuted()
            } else {
                // Don't show panel if we're in any transition state
                guard !self.visibility.isUnmuting,
                      !self.visibility.isInTransition else { return }
                self.showWithAutoHide()
            }
        }
        
        audio.onInputMuteChanged = { [weak self] in
            self?.handleMuteStateChange()
        }
        
        audio.startObservingInputVolumeChanges()
        
        // Set initial state
        audio.refresh()
        visibility.displayMutedState = audio.isInputMuted  // Initialize display state
        resizeAndPositionPanel(isMuted: audio.isInputMuted, animate: false)
        panelController.panel.orderFront(nil)
        
        // Load keyboard shortcut
        print("🔍 DEBUG: About to load keyboard shortcut...")
        NSLog("🔍 DEBUG: About to load keyboard shortcut...")
        logger.debug("About to load keyboard shortcut...")
        keyboardShortcutManager.loadShortcut(audio: audio)
        print("🔍 DEBUG: Keyboard shortcut loading completed")
        NSLog("🔍 DEBUG: Keyboard shortcut loading completed")
        logger.debug("Keyboard shortcut loading completed")
        
        handleMuteStateChange()
        if !audio.isInputMuted {
            showWithAutoHide()
        }
    }

    @objc func togglePanel() {
        hideTimer?.invalidate()
        hideTimer = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
            visibility.isShowing.toggle()
        }
    }
    
    func showWithAutoHide() {
        // If mic is muted or in transition, don't show auto-hide panel
        guard !audio.isInputMuted, !visibility.isInTransition else {
            handleMuteStateChange()
            return
        }
        
        hideTimer?.invalidate()
        resizeAndPositionPanel(isMuted: false, animate: true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
            visibility.isShowing = true
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
                self.visibility.isShowing = false
            }
        }
    }
    
    func showVolumeWhileMuted() {
        hideTimer?.invalidate()
        visibility.isInTransition = true
        
        // Show narrow mute panel
        resizeAndPositionPanel(isMuted: true, animate: true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
            visibility.isShowing = true
        } completion: {
            self.visibility.isInTransition = false
        }
        
        // Auto-hide after 3 seconds
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
                self.visibility.isShowing = false
            }
        }
    }
    
    func handleMuteStateChange() {
        let isMuted = audio.isInputMuted
        
        if isMuted {
            hideTimer?.invalidate()
            hideTimer = nil
            visibility.isUnmuting = false
            visibility.isInTransition = true
            visibility.displayMutedState = true  // Update display state immediately
            
            if !visibility.isShowing {
                // Position based on muted state for proper alignment
                resizeAndPositionPanel(isMuted: true, animate: false)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0)) {
                    visibility.isShowing = true
                } completion: {
                    self.visibility.isInTransition = false
                }
            } else {
                // Already showing, reposition for muted state
                resizeAndPositionPanel(isMuted: true, animate: false)
                visibility.isInTransition = false
            }
        } else {
            // When unmuting, transition to volume slider panel
            hideTimer?.invalidate()
            hideTimer = nil
            visibility.isUnmuting = true
            visibility.isInTransition = true
            
            // First update display state to show volume slider
            visibility.displayMutedState = false
            
            // Resize panel to full width for volume slider
            resizeAndPositionPanel(isMuted: false, animate: true)
            
            // Keep panel visible and reset flags after resize animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.visibility.isUnmuting = false
                self.visibility.isInTransition = false
                
                // Show volume slider with auto-hide
                self.showWithAutoHide()
            }
        }
    }

    private func resizeAndPositionPanel(isMuted: Bool, animate: Bool) {
        // Use different panel sizes based on state
        let panelSize = isMuted ? mutedSize : standardSize
        
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let x = (f.midX - panelSize.width / 2).rounded()
        
        // Position based on panel size
        let y = (f.maxY - panelSize.height).rounded()
        let minY = (screen.visibleFrame.minY + 10).rounded()
        let clampedY = max(y, minY)
        let finalRect = NSRect(x: x, y: clampedY, width: panelSize.width, height: panelSize.height)

        // Use smooth spring animation for better visual experience
        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                panelController.panel.setFrame(finalRect, display: true)
            })
        } else {
            panelController.panel.setFrame(finalRect, display: true, animate: false)
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePanel(); return }
        switch event.type {
        case .rightMouseUp:
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        default:
            // If muted, clicking the status item unmutes
            if audio.isInputMuted {
                audio.setInputMute(false)
            } else {
                togglePanel()
            }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    
    private func showAccessibilityAlert() {
        print("🔍 DEBUG: Showing accessibility alert")
        NSLog("🔍 DEBUG: Showing accessibility alert")
        
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Voxport needs accessibility permissions to monitor global keyboard shortcuts.\n\n1. Click 'Open System Settings'\n2. Click the '+' button under the app list\n3. Select Voxport from Applications folder\n4. Make sure the toggle is turned on\n\nAfter enabling permissions, restart Voxport."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        print("🔍 DEBUG: Alert response: \(response.rawValue)")
        NSLog("🔍 DEBUG: Alert response: \(response.rawValue)")
        
        if response == .alertFirstButtonReturn {
            print("🔍 DEBUG: Opening System Settings")
            NSLog("🔍 DEBUG: Opening System Settings")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    // MARK: - Accessibility Permissions
    private func requestAccessibilityPermissions() {
        print("🔍 DEBUG: requestAccessibilityPermissions called")
        NSLog("🔍 DEBUG: requestAccessibilityPermissions called")
        logger.debug("requestAccessibilityPermissions called")
        
        // Check if we already have permissions
        let accessibilityEnabled = AXIsProcessTrusted()
        print("🔍 DEBUG: AXIsProcessTrusted() returned: \(accessibilityEnabled)")
        NSLog("🔍 DEBUG: AXIsProcessTrusted() returned: \(accessibilityEnabled)")
        logger.debug("AXIsProcessTrusted() returned: \(accessibilityEnabled)")
        
        if !accessibilityEnabled {
            print("⚠️ DEBUG: Accessibility not enabled - attempting to request permissions")
            NSLog("⚠️ DEBUG: Accessibility not enabled - attempting to request permissions")
            logger.debug("Accessibility not enabled - attempting to request permissions")
            
            // Request accessibility permissions using a non-blocking approach
            DispatchQueue.main.async {
                self.showAccessibilityAlert()
            }
        } else {
            print("🔍 DEBUG: Accessibility already enabled")
            NSLog("🔍 DEBUG: Accessibility already enabled")
            logger.debug("Accessibility already enabled")
        }
    }
    
    @objc private func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environmentObject(keyboardShortcutManager)
                .environmentObject(audio)
            let hostingView = NSHostingView(rootView: settingsView)
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            
            window.title = "Voxport Settings"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil as Any?)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSPanel that hosts the SwiftUI view
final class NotchPanelController {
    let panel: NSPanel

    init<Content: View>(content: Content, audio: SystemAudio, visibility: VisibilityManager) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        let hostingView = NSHostingView(rootView: AnyView(
            content
                .environmentObject(audio)
                .environmentObject(visibility)
        ))

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.ignoresMouseEvents = true // Pass clicks through the transparent parts
    }
}

// MARK: - SwiftUI content
struct ContentView: View {
    @EnvironmentObject private var audio: SystemAudio
    @EnvironmentObject private var visibility: VisibilityManager

    var body: some View {
        ZStack {
            Group {
                if visibility.displayMutedState {
                    // Show muted indicator - it will be centered in the appropriate panel size
                    MutedIndicatorView()
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0).combined(with: .opacity),
                            removal: .scale(scale: 0).combined(with: .opacity)
                        ))
                } else {
                    VolumeSliderView()
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0).combined(with: .opacity),
                            removal: .scale(scale: 0).combined(with: .opacity)
                        ))
                }
            }
            .scaleEffect(visibility.isShowing ? 1.0 : 0.0, anchor: .top)
            .opacity(visibility.isShowing ? 1.0 : 0.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0), value: visibility.isShowing)
        }
        .onAppear {
            audio.refresh()
        }
    }
}

struct MutedIndicatorView: View {
    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 18))
                .foregroundColor(.red)
        }
        .frame(width: 60, height: 45)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0)))
        .drawingGroup()
    }
}



struct VolumeSliderView: View {
    @EnvironmentObject private var audio: SystemAudio
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Color.black // 100% opaque

            // Content
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .imageScale(.large)
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 28)

                HUDSlider(value: Binding(
                    get: { Double(audio.inputVolume * 100) },
                    set: { audio.setInputVolumeScalar(Float($0/100.0)) }
                ))
                .frame(height: 6)

                Text("\(Int(round(audio.inputVolume * 100)))%")
                    .foregroundColor(.white.opacity(0.9))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12) // Symmetrical padding
        }
        .frame(width: 260, height: 45)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0)))
        .drawingGroup()
    }
}

// MARK: - Custom HUD slider
struct HUDSlider: View {
    @Binding var value: Double // 0...100

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pct = max(0, min(100, value)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)

                Capsule().fill(Color.white.opacity(0.6))
                    .frame(width: max(8, w * pct), height: 6)
                    .animation(.easeOut(duration: 0.12), value: value)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let x = max(0, min(w, g.location.x))
                        value = (x / w) * 100
                    }
            )
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var keyboardShortcutManager: KeyboardShortcutManager
    @EnvironmentObject var audio: SystemAudio
    @State private var isRecording = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Keyboard Shortcut")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 10) {
                Text("Global shortcut to toggle mute:")
                    .font(.body)
                
                Button(action: {
                    isRecording = true
                    keyboardShortcutManager.isRecording = true
                    keyboardShortcutManager.recordedShortcut = nil
                    
                    // Set up key monitoring
                    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                        if isRecording {
                            handleKeyEvent(event)
                            return nil // Consume the event
                        }
                        return event
                    }
                }) {
                    HStack {
                        if let shortcut = keyboardShortcutManager.shortcut {
                            Text(shortcut.displayString)
                                .font(.system(.body, design: .monospaced))
                        } else if let recorded = keyboardShortcutManager.recordedShortcut {
                            Text(recorded.displayString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.green)
                        } else {
                            Text(isRecording ? "Press keys..." : "Click to record")
                                .foregroundColor(isRecording ? .blue : .gray)
                        }
                    }
                    .frame(minWidth: 150)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                
                if keyboardShortcutManager.shortcut != nil {
                    Button("Remove Shortcut") {
                        keyboardShortcutManager.removeShortcut()
                    }
                    .foregroundColor(.red)
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 200)
        .onDisappear {
            isRecording = false
            keyboardShortcutManager.isRecording = false
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }
        
        let modifiers = UInt32(event.modifierFlags.rawValue) & UInt32(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        
        // Debug logging
        logger.debug("Event type: \(String(describing: event.type)), keyCode: \(event.keyCode), modifiers: \(modifiers)")
        
        // For function keys, capture on flagsChanged
        if event.type == .flagsChanged {
            let testShortcut = KeyboardShortcutManager.KeyShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers
            )
            
            logger.debug("flagsChanged - isFunctionKey: \(testShortcut.isFunctionKey)")
            
            if testShortcut.isFunctionKey {
                logger.debug("Captured function key shortcut: \(testShortcut.displayString)")
                
                keyboardShortcutManager.recordedShortcut = testShortcut
                keyboardShortcutManager.saveShortcut(testShortcut)
                keyboardShortcutManager.setupGlobalMonitor(audio: audio)
                
                // Stop recording
                isRecording = false
                keyboardShortcutManager.isRecording = false
            }
        }
        // For regular keys, capture on keyDown with at least one modifier
        else if event.type == .keyDown && modifiers != 0 {
            logger.debug("keyDown with modifiers - keyCode: \(event.keyCode), modifiers: \(modifiers)")
            
            let shortcut = KeyboardShortcutManager.KeyShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers
            )
            
            logger.debug("Captured regular key shortcut: \(shortcut.displayString)")
            
            keyboardShortcutManager.recordedShortcut = shortcut
            keyboardShortcutManager.saveShortcut(shortcut)
            keyboardShortcutManager.setupGlobalMonitor(audio: audio)
            
            // Stop recording
            isRecording = false
            keyboardShortcutManager.isRecording = false
        }
    }
}

// MARK: - NSEvent extension for key code to string conversion
extension NSEvent {
    static func KeyCarbbonKeyCodeToString(_ keyCode: UInt32) -> String? {
        // First check for function keys and special keys
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 114: return "F21"
        case 115: return "F22"
        case 116: return "F23"
        case 117: return "F24"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return " "
        case 51: return "⌫"
        case 53: return "⎋"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            // For regular keys, use UCKeyTranslate
            let currentKeyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let layoutData = TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData)
            
            guard let layoutData = layoutData else { return nil }
            let layout = unsafeBitCast(layoutData, to: CFData.self)
            let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
            
            var keysDown: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var realLength = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // No modifier for base character
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &keysDown,
                chars.count,
                &realLength,
                &chars
            )
            
            if status == noErr && realLength > 0 {
                let result = String(utf16CodeUnits: chars, count: realLength)
                // Return lowercase for base character (shift will be handled in displayString)
                return result.lowercased()
            }
            
            return nil
        }
    }
}

// MARK: - System volume control via CoreAudio

