import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()
    @State private var manualLevelDraft: Double = 5
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Group {
            switch bluetooth.phase {
            case .idle, .failed:
                deviceListScreen
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
            case .connecting(let name):
                connectingScreen(deviceName: name)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .connected:
                controlsScreen
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 1.02))
                    ))
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 560)
        .background(.regularMaterial)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: bluetooth.phase)
        .onAppear { bluetooth.refreshPairedDevices() }
        .onChange(of: bluetooth.state.manualNoiseCancelingLevel) { newValue in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                manualLevelDraft = Double(newValue)
            }
        }
    }

    // MARK: - Device list screen

    private var deviceListScreen: some View {
        VStack(spacing: 0) {
            simpleHeader(title: "Select a Device")

            if case .failed(let message) = bluetooth.phase {
                errorBanner(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if bluetooth.pairedDevices.isEmpty {
                emptyDeviceState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(bluetooth.pairedDevices.enumerated()), id: \.element.id) { index, paired in
                            DeviceRow(paired: paired) {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                                    bluetooth.connect(to: paired)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.85).delay(Double(index) * 0.04),
                                value: bluetooth.pairedDevices.count
                            )
                        }
                    }
                    .padding(16)
                }
            }

            HStack {
                Spacer()
                RefreshButton {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        bluetooth.refreshPairedDevices()
                    }
                }
                Spacer()
            }
            .padding(10)

            logDrawer
        }
    }

    private var emptyDeviceState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.4))
            Text("No paired devices found")
                .font(.system(.headline, design: .rounded))
            Text("Pair your earbuds in System Settings > Bluetooth first, then refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: - Connecting screen

    private func connectingScreen(deviceName: String) -> some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 84, height: 84)
                    .scaleEffect(pulseScale)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulseScale)

                Circle()
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 4)
                    .frame(width: 64, height: 64)

                ProgressView()
                    .controlSize(.large)
            }
            .onAppear { pulseScale = 1.15 }
            .onDisappear { pulseScale = 1.0 }

            Text("Connecting to \(deviceName)…")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.opacity)

            Text("This can take a few seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Cancel") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    bluetooth.cancelConnecting()
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Spacer()
            logDrawer
        }
    }

    // MARK: - Controls screen

    private var controlsScreen: some View {
        VStack(spacing: 0) {
            connectedHeader

            ScrollView {
                VStack(spacing: 14) {
                    batteryCard
                    soundModeCard
                    gamingModeCard
                }
                .padding(18)
            }

            logDrawer
        }
    }

    private var connectedHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "headphones")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: bluetooth.connectedDeviceName)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bluetooth.connectedDeviceName ?? "Connected")
                    .font(.system(.headline, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            IconButton(systemImage: "arrow.clockwise", help: "Refresh state") {
                bluetooth.requestState()
            }

            IconButton(systemImage: "xmark.circle", help: "Disconnect") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    bluetooth.disconnect()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Battery card

    private var batteryCard: some View {
        HStack(spacing: 0) {
            batteryColumn(label: "Left", level: bluetooth.state.leftBatteryLevel, charging: bluetooth.state.leftCharging)
            Divider().frame(height: 44)
            batteryColumn(label: "Right", level: bluetooth.state.rightBatteryLevel, charging: bluetooth.state.rightCharging)
            Divider().frame(height: 44)
            batteryColumn(label: "Case", level: bluetooth.state.caseBatteryLevel, charging: false)
        }
        .padding(.vertical, 16)
        .glassCard()
    }

    private func batteryColumn(label: String, level: Int, charging: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 4)
                    .frame(width: 44, height: 44)
                Circle()
                    .trim(from: 0, to: CGFloat(level) / 10.0)
                    .stroke(batteryColor(level), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: level)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .symbolEffect(.pulse, options: .repeating.speed(0.6))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(level * 10)%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: charging)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func batteryColor(_ level: Int) -> Color {
        if level <= 2 { return .red }
        if level <= 4 { return .orange }
        return .green
    }

    // MARK: - Sound mode card

    private var soundModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Sound", icon: "waveform")

            SoundModeSelector(selection: ambientModeBinding)

            Text(soundModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(bluetooth.state.ambientSoundMode) // re-triggers a fade when the text changes
                .transition(.opacity)

            if bluetooth.state.ambientSoundMode == 0 && bluetooth.state.noiseCancelingMode == 0 {
                Divider()
                HStack {
                    Text("Manual Strength")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(manualLevelDraft))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Slider(
                    value: $manualLevelDraft,
                    in: 0...5,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing {
                            bluetooth.setManualNoiseCancelingLevel(UInt8(manualLevelDraft))
                        }
                    }
                )
                .tint(.accentColor)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .glassCard()
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bluetooth.state.ambientSoundMode)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bluetooth.state.noiseCancelingMode)
    }

    private var soundModeDescription: String {
        switch bluetooth.state.ambientSoundMode {
        case 0: return "Blocks outside noise."
        case 1: return "Lets outside sound through."
        default: return "No noise processing."
        }
    }

    // MARK: - Gaming mode card

    private var gamingModeCard: some View {
        HStack {
            cardHeader("Gaming Mode", icon: "gamecontroller")
            Spacer()
            Toggle("", isOn: gamingModeBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(18)
        .glassCard()
    }

    // MARK: - Bindings

    private var ambientModeBinding: Binding<UInt8> {
        Binding<UInt8>(
            get: { bluetooth.state.ambientSoundMode },
            set: { newValue in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    bluetooth.setAmbientSoundMode(newValue)
                }
            }
        )
    }

    private var gamingModeBinding: Binding<Bool> {
        Binding<Bool>(
            get: { bluetooth.state.gamingMode },
            set: { newValue in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    bluetooth.setGamingMode(newValue)
                }
            }
        )
    }

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
        }
    }

    // MARK: - Shared bits

    private func simpleHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var logDrawer: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(bluetooth.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.25), value: bluetooth.log.count)
                }
                .frame(height: 120)
                .padding(.top, 8)
            } label: {
                Label("Debug Log", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: bluetooth.log.count)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Reusable pieces

private struct DeviceRow: View {
    let paired: PairedDevice
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(isHovering ? 0.20 : 0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: "headphones")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(paired.name)
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Text(paired.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: isHovering ? 2 : 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isHovering ? 0.25 : 0), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(isHovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct SoundModeSelector: View {
    @Binding var selection: UInt8
    @Namespace private var highlight

    private let modes: [(value: UInt8, title: String, icon: String)] = [
        (0, "Noise Canceling", "waveform.path.ecg"),
        (1, "Transparency", "ear"),
        (2, "Normal", "speaker.wave.2")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.value) { mode in
                SoundModeButton(
                    title: mode.title,
                    icon: mode.icon,
                    isSelected: selection == mode.value,
                    namespace: highlight
                ) {
                    selection = mode.value
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.tertiary)
        )
    }
}

private struct SoundModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .matchedGeometryEffect(id: "selectedMode", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(isHovering ? Color.secondary.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.08 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct RefreshButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @State private var spinToken = 0

    var body: some View {
        Button {
            spinToken += 1
            action()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.subheadline)
                .symbolEffect(.rotate, value: spinToken)
        }
        .buttonStyle(.borderless)
        .opacity(isHovering ? 0.75 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private extension View {
    func glassCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}
