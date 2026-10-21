// Purpose: Reads raw touches from every Multi-Touch trackpad and reports the gestures they form.

import AppKit
import Foundation
import IOKit
import Synchronization

/// AppKit only delivers trackpad touches to the app under the pointer, so system-wide
/// gestures come from the private MultitouchSupport framework instead, the same source
/// tools like BetterTouchTool read. It is loaded at runtime: if a future macOS drops or
/// changes it, `start()` reports that and the rest of the app carries on.
final class TrackpadGestureMonitor {
    var onGesture: ((TrackpadGesture) -> Void)?

    private var devices: CFArray?
    private var notificationPort: IONotificationPortRef?
    private var deviceIterators: [io_iterator_t] = []
    private var wakeObserver: NSObjectProtocol?
    private var restartGeneration = 0

    private static weak var activeMonitor: TrackpadGestureMonitor?
    private nonisolated static let recognizers = Mutex<[UInt: TrackpadGestureRecognizer]>([:])
    private static let restartDelay: TimeInterval = 1

    var isRunning: Bool { devices != nil }

    deinit {
        stop()
    }

    /// Starts listening, or does nothing if already listening. Returns false when the
    /// Multi-Touch framework is unavailable on this Mac.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard let framework = MultitouchFramework.shared else { return false }

        Self.activeMonitor = self
        startDevices(with: framework)
        watchForDeviceChanges()
        return true
    }

    func stop() {
        restartGeneration += 1
        stopWatchingForDeviceChanges()
        stopDevices()
        if Self.activeMonitor === self {
            Self.activeMonitor = nil
        }
    }

    private func startDevices(with framework: MultitouchFramework) {
        let list = framework.createDeviceList()
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index),
                  !framework.isMouse(device) else {
                continue
            }
            framework.registerCallback(device, Self.contactFrameCallback)
            framework.startDevice(device, 0)
        }
        devices = list
    }

    private func stopDevices() {
        guard let devices, let framework = MultitouchFramework.shared else { return }
        for index in 0..<CFArrayGetCount(devices) {
            guard let device = CFArrayGetValueAtIndex(devices, index),
                  !framework.isMouse(device) else {
                continue
            }
            framework.unregisterCallback(device, Self.contactFrameCallback)
            framework.stopDevice(device)
        }
        // The list holds the only references to the devices, so dropping it releases them.
        self.devices = nil
        Self.recognizers.withLock { $0.removeAll() }
    }

    /// The device list is a snapshot, and a trackpad stops reporting after sleep. Rebuild
    /// it whenever a trackpad connects or disconnects, and after waking.
    private func watchForDeviceChanges() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notificationType in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port,
                notificationType,
                IOServiceMatching("AppleMultitouchDevice"),
                { refcon, iterator in
                    TrackpadGestureMonitor.drain(iterator)
                    guard let refcon else { return }
                    // The port's source is on the main run loop.
                    MainActor.assumeIsolated {
                        Unmanaged<TrackpadGestureMonitor>.fromOpaque(refcon).takeUnretainedValue().scheduleRestart()
                    }
                },
                refcon,
                &iterator
            )
            guard status == KERN_SUCCESS else { continue }
            // Draining arms the notification. What is already attached is in the list.
            Self.drain(iterator)
            deviceIterators.append(iterator)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRestart()
            }
        }
    }

    private func stopWatchingForDeviceChanges() {
        for iterator in deviceIterators {
            IOObjectRelease(iterator)
        }
        deviceIterators.removeAll()

        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// A newly attached trackpad is not ready the moment it is announced, and one
    /// connection can announce several devices, so wait a moment and restart once.
    private func scheduleRestart() {
        restartGeneration += 1
        let generation = restartGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            guard let self, self.restartGeneration == generation, self.isRunning,
                  let framework = MultitouchFramework.shared else {
                return
            }
            self.stopDevices()
            self.startDevices(with: framework)
        }
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        var object = IOIteratorNext(iterator)
        while object != 0 {
            IOObjectRelease(object)
            object = IOIteratorNext(iterator)
        }
    }

    /// Called on each device's own thread, once per frame while any finger is near the surface.
    private nonisolated static let contactFrameCallback: MultitouchFramework.ContactFrameCallback = { device, contacts, count, timestamp, _ in
        let touches = MultitouchFramework.touchingFingers(in: contacts, count: Int(count))
        let deviceKey = UInt(bitPattern: device)
        let gesture = recognizers.withLock { recognizers in
            recognizers[deviceKey, default: TrackpadGestureRecognizer()].process(touches, at: timestamp)
        }

        if let gesture {
            DispatchQueue.main.async {
                activeMonitor?.onGesture?(gesture)
            }
        }
        return 0
    }
}

/// The handful of MultitouchSupport functions the monitor needs, looked up by name.
private nonisolated struct MultitouchFramework: Sendable {
    typealias DeviceRef = UnsafeRawPointer
    typealias ContactFrameCallback = @convention(c) (
        _ device: UnsafeMutableRawPointer?,
        _ contacts: UnsafeMutableRawPointer?,
        _ count: Int32,
        _ timestamp: Double,
        _ frame: Int32
    ) -> Int32

    private let copyDeviceList: @convention(c) () -> Unmanaged<CFArray>?
    let registerCallback: @convention(c) (DeviceRef?, ContactFrameCallback) -> Void
    let unregisterCallback: @convention(c) (DeviceRef?, ContactFrameCallback) -> Void
    let startDevice: @convention(c) (DeviceRef?, Int32) -> Void
    let stopDevice: @convention(c) (DeviceRef?) -> Void
    private let getFamilyID: (@convention(c) (DeviceRef?, UnsafeMutablePointer<Int32>) -> Int32)?

    static let shared = MultitouchFramework()

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createDeviceList = dlsym(handle, "MTDeviceCreateList"),
              let registerCallback = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregisterCallback = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let startDevice = dlsym(handle, "MTDeviceStart"),
              let stopDevice = dlsym(handle, "MTDeviceStop") else {
            return nil
        }

        self.copyDeviceList = unsafeBitCast(createDeviceList, to: (@convention(c) () -> Unmanaged<CFArray>?).self)
        self.registerCallback = unsafeBitCast(registerCallback, to: (@convention(c) (DeviceRef?, ContactFrameCallback) -> Void).self)
        self.unregisterCallback = unsafeBitCast(unregisterCallback, to: (@convention(c) (DeviceRef?, ContactFrameCallback) -> Void).self)
        self.startDevice = unsafeBitCast(startDevice, to: (@convention(c) (DeviceRef?, Int32) -> Void).self)
        self.stopDevice = unsafeBitCast(stopDevice, to: (@convention(c) (DeviceRef?) -> Void).self)
        self.getFamilyID = dlsym(handle, "MTDeviceGetFamilyID").map {
            unsafeBitCast($0, to: (@convention(c) (DeviceRef?, UnsafeMutablePointer<Int32>) -> Int32).self)
        }
    }

    func createDeviceList() -> CFArray {
        copyDeviceList()?.takeRetainedValue() ?? ([] as CFArray)
    }

    /// A Magic Mouse is a Multi-Touch device too, but holding one rests several fingers
    /// on it, which would read as taps.
    func isMouse(_ device: DeviceRef) -> Bool {
        guard let getFamilyID else { return false }
        var familyID: Int32 = 0
        guard getFamilyID(device, &familyID) == 0 else { return false }
        return Self.magicMouseFamilyIDs.contains(familyID)
    }

    private static let magicMouseFamilyIDs: Set<Int32> = [112, 113]

    // Each contact is a 96-byte C struct. Only these fields are read.
    private static let contactStride = 96
    private static let identifierOffset = 16
    private static let stateOffset = 20
    private static let normalizedXOffset = 32
    private static let normalizedYOffset = 36
    /// Contact states 3 and 4: the finger has just touched down, or is still down.
    /// Hovering and lifting contacts are left out.
    private static let touchingStates: ClosedRange<Int32> = 3...4

    static func touchingFingers(in contacts: UnsafeMutableRawPointer?, count: Int) -> [TrackpadTouch] {
        guard let contacts, count > 0 else { return [] }

        var touches: [TrackpadTouch] = []
        touches.reserveCapacity(count)
        for index in 0..<count {
            let contact = contacts + index * contactStride
            guard touchingStates.contains(contact.load(fromByteOffset: stateOffset, as: Int32.self)) else { continue }
            touches.append(TrackpadTouch(
                identifier: Int(contact.load(fromByteOffset: identifierOffset, as: Int32.self)),
                position: CGPoint(
                    x: CGFloat(contact.load(fromByteOffset: normalizedXOffset, as: Float.self)),
                    y: CGFloat(contact.load(fromByteOffset: normalizedYOffset, as: Float.self))
                )
            ))
        }
        return touches
    }
}
