import Foundation
import IOBluetooth
import Combine

// MARK: - Packet framing (shared by all Soundcore devices)

struct SoundcorePacket {
    static let outboundDirection: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]
    static let inboundDirection: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01]

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    static func build(command: (UInt8, UInt8), body: [UInt8]) -> Data {
        var bytes = outboundDirection
        bytes.append(contentsOf: [command.0, command.1])
        let totalLength = UInt16(5 + 2 + 2 + body.count + 1)
        bytes.append(contentsOf: withUnsafeBytes(of: totalLength.littleEndian, Array.init))
        bytes.append(contentsOf: body)
        bytes.append(checksum(bytes))
        return Data(bytes)
    }

    static let requestState = build(command: (0x01, 0x01), body: [])

    static func setGamingMode(_ enabled: Bool) -> Data {
        build(command: (0x10, 0x85), body: [enabled ? 1 : 0])
    }

    static func setSoundModes(
        ambient: UInt8, manualLevel: UInt8, adaptive: UInt8,
        transparency: UInt8, noiseCancelingMode: UInt8,
        windNoise: UInt8, adaptiveSensitivity: UInt8, transportation: UInt8
    ) -> Data {
        let manualAdaptiveByte = (manualLevel << 4) | (adaptive & 0x0F)
        let body: [UInt8] = [
            ambient, manualAdaptiveByte, transparency, noiseCancelingMode,
            windNoise, adaptiveSensitivity, transportation
        ]
        return build(command: (0x06, 0x81), body: body)
    }
}

// MARK: - Parsed device state (Liberty 5 / A3957 field offsets, verified against source)

struct A3957State {
    var ambientSoundMode: UInt8 = 0
    var manualNoiseCancelingLevel: UInt8 = 5
    var noiseCancelingMode: UInt8 = 0
    var gamingMode: Bool = false

    var leftBatteryLevel: Int = 0
    var rightBatteryLevel: Int = 0
    var caseBatteryLevel: Int = 0+
    var leftCharging: Bool = false
    var rightCharging: Bool = false

    static func parse(body: [UInt8]) -> A3957State? {
        guard body.count >= 147 else { return nil }
        var s = A3957State()
        s.leftBatteryLevel = Int(body[2]) + 1
        s.rightBatteryLevel = Int(body[3]) + 1
        s.leftCharging = body[4] != 0
        s.rightCharging = body[5] != 0
        s.caseBatteryLevel = Int(body[37]) + 1
        s.ambientSoundMode = body[119]
        s.manualNoiseCancelingLevel = body[120] >> 4
        s.noiseCancelingMode = body[122]
        s.gamingMode = body[146] != 0
        return s
    }
}

// MARK: - Device list model

struct PairedDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let device: IOBluetoothDevice

    static func == (lhs: PairedDevice, rhs: PairedDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Connection phase

enum ConnectionPhase: Equatable {
    case idle
    case connecting(deviceName: String)
    case connected
    case failed(message: String)
}

// MARK: - Bluetooth manager

final class BluetoothManager: NSObject, ObservableObject {
    @Published var pairedDevices: [PairedDevice] = []
    @Published var phase: ConnectionPhase = .idle
    @Published var connectedDeviceName: String?
    @Published var state = A3957State()
    @Published var log: [String] = []

    private var channel: IOBluetoothRFCOMMChannel?
    private var incomingBuffer = [UInt8]()
    private var connectionGeneration = 0

    // MARK: Device discovery

    func refreshPairedDevices() {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        pairedDevices = devices.map {
            PairedDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Unknown Device", device: $0)
        }
        appendLog("Found \(pairedDevices.count) paired device(s).")
    }

    // MARK: Connect / disconnect

    func connect(to paired: PairedDevice) {
        connectionGeneration += 1
        let myGeneration = connectionGeneration

        phase = .connecting(deviceName: paired.name)
        connectedDeviceName = paired.name
        appendLog("Querying SDP services on \(paired.name)...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.connectionGeneration == myGeneration else { return }
            if case .connecting = self.phase {
                self.appendLog("Timed out waiting for a response.")
                self.phase = .failed(message: "Timed out connecting. Try again, or toggle Bluetooth off/on.")
            }
        }

        paired.device.performSDPQuery(self)
    }

    func cancelConnecting() {
        connectionGeneration += 1
        phase = .idle
        appendLog("Connection attempt cancelled.")
    }

    func disconnect() {
        connectionGeneration += 1
        channel?.close()
        channel = nil
        phase = .idle
        connectedDeviceName = nil
        appendLog("Disconnected.")
    }

    private func openRFCOMMChannel(on device: IOBluetoothDevice, generation: Int) {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            appendLog("No SDP services found.")
            phase = .failed(message: "No Bluetooth services found on that device.")
            return
        }

        var foundChannelID: BluetoothRFCOMMChannelID = 0
        var found = false
        for service in services {
            var channelID: BluetoothRFCOMMChannelID = 0
            if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                appendLog("Found RFCOMM service \"\(service.getServiceName() ?? "?")\" on channel \(channelID)")
                foundChannelID = channelID
                found = true
                if (service.getServiceName() ?? "").localizedCaseInsensitiveContains("serial") {
                    break
                }
            }
        }

        guard found else {
            appendLog("No RFCOMM channel found in SDP records.")
            phase = .failed(message: "This device doesn't expose a serial (RFCOMM) service.")
            return
        }

        var rfcommChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelSync(&rfcommChannel, withChannelID: foundChannelID, delegate: self)

        guard self.connectionGeneration == generation else { return }

        if result == kIOReturnSuccess, let rfcommChannel {
            channel = rfcommChannel
            phase = .connected
            appendLog("RFCOMM channel \(foundChannelID) opened.")
            requestState()
        } else {
            appendLog("Failed to open RFCOMM channel \(foundChannelID) (\(result)).")
            phase = .failed(message: "Couldn't open a connection (error \(result)). Try again.")
        }
    }

    // MARK: Commands
    // Every command below updates `state` optimistically, immediately, on the main actor,
    // BEFORE the write goes out. The earbuds may or may not echo back a full state packet
    // in response (many devices only ACK), so the UI can't afford to wait on that — it drives
    // itself from the command it just issued, and requestState() is there to resync if needed.

    func requestState() {
        write(SoundcorePacket.requestState)
    }

    func setGamingMode(_ enabled: Bool) {
        state.gamingMode = enabled
        write(SoundcorePacket.setGamingMode(enabled))
    }

    func setAmbientSoundMode(_ mode: UInt8) {
        state.ambientSoundMode = mode
        write(SoundcorePacket.setSoundModes(
            ambient: mode,
            manualLevel: state.manualNoiseCancelingLevel,
            adaptive: 0,
            transparency: 0,
            noiseCancelingMode: state.noiseCancelingMode,
            windNoise: 0,
            adaptiveSensitivity: 0,
            transportation: 0
        ))
    }

    func setManualNoiseCancelingLevel(_ level: UInt8) {
        state.manualNoiseCancelingLevel = level
        write(SoundcorePacket.setSoundModes(
            ambient: state.ambientSoundMode,
            manualLevel: level,
            adaptive: 0,
            transparency: 0,
            noiseCancelingMode: state.noiseCancelingMode,
            windNoise: 0,
            adaptiveSensitivity: 0,
            transportation: 0
        ))
    }

    private func write(_ data: Data) {
        guard let channel else { appendLog("Not connected."); return }
        var bytes = [UInt8](data)
        channel.writeSync(&bytes, length: UInt16(bytes.count))
    }

    private func appendLog(_ message: String) {
        if Thread.isMainThread {
            log.append(message)
        } else {
            DispatchQueue.main.async { self.log.append(message) }
        }
        print(message)
    }
}

// MARK: - SDP query callback (called via Objective-C selector, background thread)

extension BluetoothManager {
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            guard status == kIOReturnSuccess else {
                self.appendLog("SDP query failed: \(status)")
                self.phase = .failed(message: "Couldn't discover services (code \(status)).")
                return
            }
            self.appendLog("SDP query complete, \(device.services?.count ?? 0) services found.")
            self.openRFCOMMChannel(on: device, generation: generation)
        }
    }
}

// MARK: - RFCOMM channel delegate (also background thread)

extension BluetoothManager: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = [UInt8](Data(bytes: dataPointer, count: dataLength))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.incomingBuffer.append(contentsOf: bytes)

            while self.incomingBuffer.count >= 9 {
                guard Array(self.incomingBuffer.prefix(5)) == SoundcorePacket.inboundDirection else {
                    self.incomingBuffer.removeFirst()
                    continue
                }
                let totalLength = Int(self.incomingBuffer[7]) | (Int(self.incomingBuffer[8]) << 8)
                guard self.incomingBuffer.count >= totalLength else { break }
                let body = Array(self.incomingBuffer[9..<(totalLength - 1)])
                self.incomingBuffer.removeFirst(totalLength)

                // Only a full state-update packet (147+ bytes) overwrites local state here.
                // Short ACK packets are ignored rather than treated as "no change happened" —
                // the optimistic update from the command that triggered them already stands.
                if let parsed = A3957State.parse(body: body) {
                    self.state = parsed
                    self.appendLog("State updated: ambient=\(parsed.ambientSoundMode) manualNC=\(parsed.manualNoiseCancelingLevel) gaming=\(parsed.gamingMode) battery=L\(parsed.leftBatteryLevel)/R\(parsed.rightBatteryLevel)/C\(parsed.caseBatteryLevel)")
                } else {
                    self.appendLog("Received \(body.count)-byte packet (likely an ACK, not a full state dump).")
                }
            }
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionGeneration += 1
            self.channel = nil
            self.phase = .idle
            self.connectedDeviceName = nil
            self.appendLog("Channel closed.")
        }
    }
}
