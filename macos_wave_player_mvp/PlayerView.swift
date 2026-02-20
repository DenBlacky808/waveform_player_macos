import SwiftUI
import AppKit

/// Главный экран плеера.
///
/// Что здесь происходит:
/// 1) Показываем waveform + playhead.
/// 2) Даём базовые кнопки управления.
/// 3) Ловим жесты мыши для scrub/seek.
/// 4) Ловим дополнительные hotkeys через NSEvent-монитор.
struct PlayerView: View {
    /// Контроллер с аудио-состоянием.
    @ObservedObject var controller: AudioEngineController
    /// Кэшированные пики waveform для быстрой отрисовки.
    @State private var peaks: [Float] = []

    var body: some View {
        VStack(spacing: 12) {
            waveformView
                .frame(minHeight: 180)

            HStack(spacing: 10) {
                // Space -> Play/Pause
                Button(controller.isPlaying ? "Pause" : "Play") {
                    controller.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                // S -> Stop
                Button("Stop") {
                    controller.stop(resetToStart: true)
                }
                .keyboardShortcut("s", modifiers: [])

                // L -> Loop
                Button(controller.isLoopEnabled ? "Loop On" : "Loop Off") {
                    controller.toggleLoop()
                }
                .keyboardShortcut("l", modifiers: [])

                Spacer()

                Text(timeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .onChange(of: controller.fileURL) { _, newURL in
            // Когда загрузился новый файл — пересчитываем waveform-пики.
            guard let newURL else {
                peaks = []
                return
            }

            do {
                peaks = try WaveformBuilder.buildPeaks(from: newURL)
            } catch {
                peaks = []
                print("Waveform build failed: \(error)")
            }
        }
        // Невидимый NSView для перехвата стрелок/Home.
        .background(KeyEventHandlingView(controller: controller))
    }

    /// Область waveform.
    ///
    /// Почему Canvas:
    /// - проще, чем писать NSView/Metal.
    /// - достаточно быстрый для MVP при заранее посчитанных peaks.
    private var waveformView: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let midY = size.height / 2

                // Фон waveform-площадки.
                var bg = Path()
                bg.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerSize: CGSize(width: 8, height: 8))
                context.fill(bg, with: .color(Color(nsColor: .windowBackgroundColor)))

                guard !peaks.isEmpty else { return }

                let widthPerSample = size.width / CGFloat(peaks.count)
                var wave = Path()

                // Рисуем вертикальные «палочки» по амплитуде peak.
                for (idx, peak) in peaks.enumerated() {
                    let x = CGFloat(idx) * widthPerSample
                    let amplitude = CGFloat(peak) * (size.height * 0.45)
                    wave.move(to: CGPoint(x: x, y: midY - amplitude))
                    wave.addLine(to: CGPoint(x: x, y: midY + amplitude))
                }

                context.stroke(
                    wave,
                    with: .color(.accentColor.opacity(0.85)),
                    lineWidth: max(1, widthPerSample * 0.8)
                )

                // Красный playhead по currentTime/duration.
                if controller.durationSeconds > 0 {
                    let ratio = max(0, min(controller.currentTimeSeconds / controller.durationSeconds, 1))
                    let playheadX = size.width * ratio
                    var playhead = Path()
                    playhead.move(to: CGPoint(x: playheadX, y: 0))
                    playhead.addLine(to: CGPoint(x: playheadX, y: size.height))
                    context.stroke(playhead, with: .color(.red), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance: 0 делает и click, и drag единым механизмом.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seek(fromX: value.location.x, width: geo.size.width)
                    }
            )
        }
    }

    private var timeText: String {
        let current = format(seconds: controller.currentTimeSeconds)
        let total = format(seconds: controller.durationSeconds)
        return "\(current) / \(total)"
    }

    /// Перемотка по X-координате в waveform.
    private func seek(fromX x: CGFloat, width: CGFloat) {
        guard controller.durationSeconds > 0 else { return }
        let clamped = max(0, min(x, width))
        let ratio = width > 0 ? clamped / width : 0
        controller.seek(seconds: controller.durationSeconds * ratio)
    }

    /// Формат времени `mm:ss`.
    private func format(seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let intValue = Int(seconds)
        let minutes = intValue / 60
        let secs = intValue % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// Обёртка над `NSEvent.addLocalMonitorForEvents`,
/// чтобы добавить хоткеи, которых неудобно добиться только SwiftUI-shortcut'ами.
private struct KeyEventHandlingView: NSViewRepresentable {
    let controller: AudioEngineController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator {
        private weak var monitor: AnyObject?
        private let controller: AudioEngineController

        init(controller: AudioEngineController) {
            self.controller = controller
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func startMonitoring() {
            let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                switch event.keyCode {
                case 123: // Left Arrow
                    let step = event.modifierFlags.contains(.shift) ? -5.0 : -1.0
                    controller.seekBy(deltaSeconds: step)
                    return nil
                case 124: // Right Arrow
                    let step = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
                    controller.seekBy(deltaSeconds: step)
                    return nil
                case 115: // Home
                    controller.seek(seconds: 0)
                    return nil
                default:
                    return event
                }
            }

            monitor = eventMonitor as AnyObject
        }
    }
}
