import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct GlicStudioApp: App {
    @State private var model = GlicModel()

    var body: some Scene {
        WindowGroup("GLIC Studio") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}

struct ContentView: View {
    @Bindable var model: GlicModel

    var body: some View {
        HSplitView {
            imagePane
                .frame(minWidth: 480)
                .layoutPriority(1)
            ScrollView { controls.padding(16) }
                .frame(width: 300)
        }
    }

    private var imagePane: some View {
        ZStack {
            Color(white: 0.1)
            if let img = model.displayImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
            } else {
                ProgressView()
            }
            VStack {
                Spacer()
                Text(model.status)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Source", selection: Binding(
                get: { model.source },
                set: { model.setSource($0) }
            )) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.source == .image {
                HStack {
                    Button("Open…") { openImage() }
                    Button("Random") { model.loadSynthetic() }
                }
            } else {
                Picker("Camera res", selection: $model.cameraWidth) {
                    Text("240").tag(240)
                    Text("320").tag(320)
                    Text("480").tag(480)
                    Text("640").tag(640)
                    Text("768").tag(768)
                    Text("960").tag(960)
                    Text("1280").tag(1280)
                }
                .onChange(of: model.cameraWidth) { _, _ in model.updateCameraSettings() }

                Picker("Region", selection: $model.detectMode) {
                    ForEach(DetectMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: model.detectMode) { _, _ in model.updateCameraSettings() }

                if model.detectMode != .off {
                    Toggle("Glitch background instead", isOn: $model.glitchBackground)
                }
                if let err = model.cameraError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            group("Preset") {
                Picker("Preset", selection: $model.selectedPreset) {
                    Text("Custom (sliders)").tag(String?.none)
                    ForEach(model.presets, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .onChange(of: model.selectedPreset) { _, _ in model.scheduleCodec() }
                Text("\(model.presets.count) presets loaded")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            group("Codec") {
                picker("Color space", selection: $model.colorSpace,
                       options: Options.colorSpaces, onChange: model.scheduleCodec)
                picker("Prediction", selection: $model.prediction,
                       options: Options.predictions, onChange: model.scheduleCodec)
                picker("Wavelet", selection: $model.wavelet,
                       options: Options.wavelets, onChange: model.scheduleCodec)
                picker("Transform", selection: $model.transform,
                       options: Options.transforms, onChange: model.scheduleCodec)
                slider("Scale (raise for high quant)", value: $model.transformScale,
                       range: 4...480, onChange: model.scheduleCodec)
                picker("Encoding", selection: $model.encoding,
                       options: Options.encodings, onChange: model.scheduleCodec)
                slider("Quantization", value: $model.quantization, range: 0...255,
                       onChange: model.scheduleCodec)
                slider("Threshold", value: $model.threshold, range: 1...60,
                       onChange: model.scheduleCodec)
                picker("Min block", selection: $model.minBlock,
                       options: Options.blocks, onChange: model.scheduleCodec)
                picker("Max block", selection: $model.maxBlock,
                       options: [("64", 64), ("128", 128), ("256", 256), ("512", 512)],
                       onChange: model.scheduleCodec)
                Toggle("Clamp mod256", isOn: $model.clampMod256)
                    .onChange(of: model.clampMod256) { _, _ in model.scheduleCodec() }
            }
            .disabled(model.selectedPreset != nil)
            .opacity(model.selectedPreset != nil ? 0.4 : 1)

            group("Glitch effect (C++)") {
                picker("Effect", selection: $model.cppEffect,
                       options: Options.cppEffects, onChange: model.presentDecoded)
                if model.cppEffect != 0 {
                    slider("Intensity", value: $model.cppIntensity, range: 0...100,
                           onChange: model.presentDecoded)
                    picker("Block size", selection: $model.cppBlockSize,
                           options: [("4", 4), ("8", 8), ("16", 16), ("32", 32), ("64", 64)],
                           onChange: model.presentDecoded)
                    if model.cppEffect == 5 { // posterize
                        Stepper("Levels: \(model.cppLevels)", value: $model.cppLevels, in: 2...32)
                            .onChange(of: model.cppLevels) { _, _ in model.presentDecoded() }
                    }
                    if model.cppEffect == 8 { // pixel sort
                        picker("Sort by", selection: $model.cppSortMode,
                               options: Options.sortModes, onChange: model.presentDecoded)
                        slider("Threshold", value: $model.cppThreshold, range: 0...255,
                               onChange: model.presentDecoded)
                        Toggle("Vertical", isOn: $model.cppSortVertical)
                            .onChange(of: model.cppSortVertical) { _, _ in model.presentDecoded() }
                    }
                    if model.cppEffect == 9 { // prediction leak
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Leak: \(String(format: "%.2f", model.cppLeak))").font(.caption)
                            Slider(value: $model.cppLeak, in: 0...1)
                                .onChange(of: model.cppLeak) { _, _ in model.presentDecoded() }
                        }
                    }
                }
            }

            group("Parallelism") {
                picker("Tile size", selection: $model.tile,
                       options: Options.tiles, onChange: model.scheduleCodec)
                Stepper("Threads: \(model.threads)", value: $model.threads, in: 1...12)
                    .onChange(of: model.threads) { _, _ in model.scheduleCodec() }
            }

            group("Effects (GPU)") {
                toggleSlider("Pixelate", on: $model.effects.pixelate,
                             value: $model.effects.pixelScale, range: 1...40)
                toggleSlider("Posterize", on: $model.effects.posterize,
                             value: $model.effects.levels, range: 2...16)
                Toggle("Color", isOn: $model.effects.colorAdjust)
                    .onChange(of: model.effects.colorAdjust) { _, _ in model.applyEffects() }
                if model.effects.colorAdjust {
                    slider("Saturation", value: $model.effects.saturation, range: 0...3,
                           onChange: model.applyEffects)
                    slider("Contrast", value: $model.effects.contrast, range: 0.25...3,
                           onChange: model.applyEffects)
                }
            }
        }
    }

    // MARK: - Small control builders

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                        onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(Int(value.wrappedValue))").font(.caption)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
        }
    }

    private func picker(_ label: String, selection: Binding<Int>,
                        options: [(String, Int)], onChange: @escaping () -> Void) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
        .onChange(of: selection.wrappedValue) { _, _ in onChange() }
    }

    private func toggleSlider(_ label: String, on: Binding<Bool>,
                              value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(label, isOn: on)
                .onChange(of: on.wrappedValue) { _, _ in model.applyEffects() }
            if on.wrappedValue {
                Slider(value: value, in: range)
                    .onChange(of: value.wrappedValue) { _, _ in model.applyEffects() }
            }
        }
    }

    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
        }
    }
}
