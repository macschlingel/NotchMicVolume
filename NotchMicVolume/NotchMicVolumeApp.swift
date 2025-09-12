//
//  NotchMicVolumeApp.swift
//  NotchMicVolume
//
//  Created by Bastian Wölfle on 19.08.25.
//
import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import QuartzCore

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
struct NotchMicVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Global state for HUD visibility
final class VisibilityManager: ObservableObject {
    @Published var isShowing = false
}

// MARK: - App Delegate manages the top-centered panel AND CLI
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audio = SystemAudio()
    let visibility = VisibilityManager()
    private var panelController: NotchPanelController!
    private var statusItem: NSStatusItem!
    private var hideTimer: Timer?

    private let mutedSize = NSSize(width: 60, height: 45)
    private let standardSize = NSSize(width: 260, height: 60)

    private lazy var statusMenu: NSMenu = {
        let m = NSMenu()
        let quit = NSMenuItem(title: "Quit NotchMicVolume", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        return m
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Status item (left click shows HUD, right click opens menu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NotchMicVolume")
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
        dnc.addObserver(forName: NSNotification.Name("NotchMicVolume.SetInputVolumePercent"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let pct = note.userInfo?["percent"] as? Int { self.audio.setInputVolumePercent(pct); self.showWithAutoHide() }
        }
        dnc.addObserver(forName: NSNotification.Name("NotchMicVolume.ChangeInputVolumeBy"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let delta = note.userInfo?["delta"] as? Int { self.audio.changeInputVolumeBy(delta); self.showWithAutoHide() }
        }

        // When system input volume changes (from anywhere), refresh and show for 5s
        audio.onInputVolumeChanged = { [weak self] in
            self?.audio.refresh()
            self?.showWithAutoHide()
        }
        
        audio.onInputMuteChanged = { [weak self] in
            self?.handleMuteStateChange()
        }
        
        audio.startObservingInputVolumeChanges()
        
        // Set initial state
        audio.refresh()
        resizeAndPositionPanel(isMuted: audio.isInputMuted, animate: false)
        panelController.panel.orderFront(nil)
        
        handleMuteStateChange()
        if !audio.isInputMuted {
            showWithAutoHide()
        }
    }

    @objc func togglePanel() {
        hideTimer?.invalidate()
        hideTimer = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            visibility.isShowing.toggle()
        }
    }
    
    func showWithAutoHide() {
        // If mic is muted, the indicator is shown permanently, so don't auto-hide.
        guard !audio.isInputMuted else {
            handleMuteStateChange()
            return
        }
        
        hideTimer?.invalidate()
        resizeAndPositionPanel(isMuted: false, animate: true)
        withAnimation(.easeInOut(duration: 0.2)) {
            visibility.isShowing = true
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.visibility.isShowing = false
            } completion: {
                // Animation completed - panel can now be safely repositioned if needed
            }
        }
    }
    
    func handleMuteStateChange() {
        let isMuted = audio.isInputMuted
        
        if isMuted {
            hideTimer?.invalidate()
            hideTimer = nil
            
            if !visibility.isShowing {
                // Position based on muted state for proper alignment
                resizeAndPositionPanel(isMuted: true, animate: false)
                withAnimation(.easeInOut(duration: 0.2)) {
                    visibility.isShowing = true
                }
            } else {
                // Already showing, reposition for muted state
                resizeAndPositionPanel(isMuted: true, animate: false)
            }
        } else {
            // When unmuting, position based on standard size and animate out
            resizeAndPositionPanel(isMuted: false, animate: false)
            if visibility.isShowing {
                withAnimation(.easeInOut(duration: 0.2)) {
                    visibility.isShowing = false
                } completion: {
                    // Animation completed
                }
            }
        }
    }

    private func resizeAndPositionPanel(isMuted: Bool, animate: Bool) {
        // Always use standard size for the panel, but position based on visual content size
        let panelSize = standardSize
        let visualSize = isMuted ? mutedSize : standardSize
        
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let x = (f.midX - panelSize.width / 2).rounded()
        
        // Position based on visual content size so it appears at the right location
        let y = (f.maxY - visualSize.height).rounded()
        let minY = (screen.visibleFrame.minY + 10).rounded()
        let clampedY = max(y, minY)
        let finalRect = NSRect(x: x, y: clampedY, width: panelSize.width, height: panelSize.height)

        // Disable AppKit animation to let SwiftUI handle the visual transitions
        panelController.panel.setFrame(finalRect, display: true, animate: false)
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
                if audio.isInputMuted {
                    // Center the muted indicator within the standard panel frame
                    MutedIndicatorView()
                        .frame(width: 260, height: 60) // Match VolumeSliderView frame
                } else {
                    VolumeSliderView()
                }
            }
            .scaleEffect(visibility.isShowing ? 1.0 : 0.0, anchor: .top)
            .opacity(visibility.isShowing ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.2), value: visibility.isShowing)
            .animation(.easeInOut(duration: 0.2), value: audio.isInputMuted)
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
        .frame(width: 260, height: 60)
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

// MARK: - System volume control via CoreAudio

