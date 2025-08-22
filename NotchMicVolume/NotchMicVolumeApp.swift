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

// MARK: - Entry point
@main
struct NotchMicVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate manages the top-centered panel AND CLI
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audio = SystemAudio()
    private var panelController: NotchPanelController!
    private var statusItem: NSStatusItem!
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
        // Absolute:  NotchMicVolume --set-input-volume 37
        // Relative:  NotchMicVolume --change-input-volume +5 / -10
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
        panelController = NotchPanelController(content: ContentView(), audio: audio)

        // Listen for external script commands via Distributed Notification Center
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("NotchMicVolume.SetInputVolumePercent"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let pct = note.userInfo?["percent"] as? Int { self.audio.setInputVolumePercent(pct); self.panelController.showTemporarily() }
        }
        dnc.addObserver(forName: NSNotification.Name("NotchMicVolume.ChangeInputVolumeBy"), object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let delta = note.userInfo?["delta"] as? Int { self.audio.changeInputVolumeBy(delta); self.panelController.showTemporarily() }
        }

        // When system input volume changes (from anywhere), refresh and show for 5s
        audio.onInputVolumeChanged = { [weak self] in
            self?.audio.refresh()
            self?.panelController.showTemporarily()
        }
        audio.startObservingInputVolumeChanges()
        panelController.showTemporarily()
    }

    @objc func togglePanel() { panelController.showTemporarily() }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { panelController.showTemporarily(); return }
        switch event.type {
        case .rightMouseUp:
            // Temporarily assign a menu to show the context menu on right click only
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        default:
            panelController.showTemporarily()
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - NSPanel that drops from the top center, overlapping the notch/menu bar
final class NotchPanelController: NSObject {
    private let panel: NSPanel
    private var isShown = false
    private let panelSize = NSSize(width: 260, height: 60)
    private let scaleStart: CGFloat = 0.86
    private var hosting: NSHostingView<AnyView>!
    private var container: NSView!


    private static func scaledRect(target: NSRect, scale: CGFloat) -> NSRect {
        let newW = target.width * scale
        let newH = target.height * scale
        let x = target.midX - newW / 2
        let y = target.maxY - newH // keep top anchored
        return NSRect(x: x, y: y, width: newW, height: newH)
    }

    // MARK: - Layer anchor/animation helpers
    private func applyTopCenterAnchor() {
        hosting.wantsLayer = true
        guard let layer = hosting.layer else { return }
        let f = hosting.frame // superlayer coords
        layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)    // top-center
        layer.position = CGPoint(x: f.midX, y: f.maxY) // pin to top edge in superlayer space
    }

    private func animateScale(to scale: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName, completion: (() -> Void)? = nil) {
        guard let layer = hosting.layer else { completion?(); return }
        let toTransform = CATransform3DMakeScale(scale, scale, 1)
        let fromTransform = layer.transform
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = fromTransform
        anim.toValue = toTransform
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timing)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "nmv.scale")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            layer.transform = toTransform
            layer.removeAnimation(forKey: "nmv.scale")
            completion?()
        }
    }


    init<Content: View>(content: Content, audio: SystemAudio) {
        hosting = NSHostingView(rootView: AnyView(
            content
                .environmentObject(audio)
                .frame(width: panelSize.width, height: panelSize.height)
        ))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 0
        hosting.layer?.masksToBounds = false
        hosting.alphaValue = 1 // ensure we see the scale; we'll avoid full-view fade

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered,
                        defer: false)
        container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        panel.contentView = container
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        container.addSubview(hosting)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // custom shadow drawn in SwiftUI
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.animationBehavior = .none

        super.init()
        self.applyTopCenterAnchor()

        // park offscreen (hidden)
        if let targetRect = Self.targetRect(size: panelSize) {
            let hiddenRect = NSRect(x: targetRect.origin.x, y: targetRect.maxY, width: targetRect.width, height: 0)
            panel.setFrame(hiddenRect, display: false)
        }
    }

    func toggle() { isShown ? hide() : show() }

    func showTemporarily(_ seconds: TimeInterval = 5) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.hide()
        }
    }

    private func show() {
        guard let targetRect = Self.targetRect(size: panelSize) else { return }
        // Ensure anchor and starting transform are correct before showing
        self.applyTopCenterAnchor()
        hosting.layer?.transform = CATransform3DMakeScale(scaleStart, scaleStart, 1)

        // Put window at final frame, then show
        panel.setFrame(targetRect, display: false)
        if !panel.isVisible { panel.orderFrontRegardless() }

        // Animate scale up to 1.0 anchored at top-center
        animateScale(to: 1.0, duration: 0.22, timing: .easeOut) { [weak self] in
            self?.isShown = true
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        // Ensure anchor is correct before animating out
        self.applyTopCenterAnchor()

        animateScale(to: scaleStart, duration: 0.18, timing: .easeIn) { [weak self] in
            guard let self = self else { return }
            self.panel.orderOut(nil)
            self.isShown = false
        }
    }

    static func targetRect(size: NSSize) -> NSRect? {
        guard let screen = NSScreen.main else { return nil }
        let f = screen.frame
        // Center horizontally; sit just below top edge to overlay notch/menu bar
        let x = (f.midX - size.width / 2).rounded()
        // Sit flush to the top edge; ears are inverse overlays at the same top line
        let y = (f.maxY - size.height).rounded()
        // Avoid going below visible frame on very small displays
        let minY = (screen.visibleFrame.minY + 10).rounded()
        let clampedY = max(y, minY)
        return NSRect(x: x, y: clampedY, width: size.width.rounded(), height: size.height.rounded())
    }
}

// MARK: - SwiftUI content (name kept as ContentView to satisfy Xcode template references)
struct ContentView: View {
    @EnvironmentObject private var audio: SystemAudio
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Flat-top box; bottom corners rounded. Ears are separate tiny panels.
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0))
                .fill(Color.black)

            // Content padding lives above the shape, so it doesn't push the top edge down
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
            .padding(.bottom, 6)
        }
        .onAppear { audio.refresh() }
    }

    private func iconFor(value: Float) -> String {
        switch value {
        case 0: return "speaker.fill"
        case 0..<0.34: return "speaker.wave.1.fill"
        case 0.34..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}


// (ear helpers removed)

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
final class SystemAudio: ObservableObject {
    @Published var volume: Float = 0 // 0.0 - 1.0 (OUTPUT)
    @Published var isMuted: Bool = false
    @Published var inputVolume: Float = 0 // 0.0 - 1.0 (INPUT)

    private var volumeListenerAddresses: [AudioObjectPropertyAddress] = []
    private var isObserving = false
    var onInputVolumeChanged: (() -> Void)?

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
            self.registerInputVolumeListeners()
            self.onInputVolumeChanged?()
        }
        registerInputVolumeListeners()
    }

    private func registerInputVolumeListeners() {
        // Remove old references (listeners are not explicitly removed here for brevity)
        volumeListenerAddresses.removeAll()
        let elements = inputVolumeElements()
        for elem in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: elem
            )
            volumeListenerAddresses.append(addr)
            AudioObjectAddPropertyListenerBlock(inputDeviceID, &addr, .main) { [weak self] _, _ in
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

// MARK: - Transparent blur background for the HUD look
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
