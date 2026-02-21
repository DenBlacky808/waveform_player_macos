import AVFAudio
import Foundation

/// Центральный контроллер аудио-логики для MVP-плеера.
///
/// Почему именно отдельный класс:
/// - SwiftUI-View должна быть максимально «тонкой» (только UI).
/// - Здесь хранится всё состояние воспроизведения, чтобы его было легко
///   тестировать и расширять.
///
/// Почему `@MainActor`:
/// - `@Published`-свойства читаются UI.
/// - Обновление UI-состояния из главного потока снижает риск гонок данных.
@MainActor
final class AudioEngineController: ObservableObject {
    /// URL текущего открытого файла (используется UI для реакции на смену файла).
    @Published var fileURL: URL?
    /// Идёт ли воспроизведение прямо сейчас.
    @Published var isPlaying = false
    /// Включён ли loop (зацикливание).
    @Published var isLoopEnabled = false
    /// Полная длительность файла в секундах.
    @Published var durationSeconds: Double = 0
    /// Текущая позиция playhead в секундах.
    @Published var currentTimeSeconds: Double = 0

    /// AVAudioEngine — граф аудио-обработки/воспроизведения.
    private let engine = AVAudioEngine()
    /// Нода-плеер, в которую мы планируем (schedule) кусок файла.
    private let playerNode = AVAudioPlayerNode()

    /// Открытый аудио-файл.
    private var audioFile: AVAudioFile?
    /// Sample rate текущего файла (нужен для конвертации секунды <-> фреймы).
    private var sampleRate: Double = 44_100
    /// Полная длина файла во фреймах.
    private var totalFrames: AVAudioFramePosition = 0
    /// Фрейм, с которого стартовало текущее/последнее schedule-воспроизведение.
    ///
    /// Важный момент: для seek мы НЕ двигаем «курсор» в AVAudioPlayerNode,
    /// а просто заново делаем scheduleSegment с новым startingFrame.
    private var lastSeekFrame: AVAudioFramePosition = 0
    /// Лёгкий poll-таймер: обновляет playhead и реализует loop на конце трека.
    private var timer: Timer?

    init() {
        setupEngine()
        startProgressTimer()
    }

    deinit {
        // На всякий случай явно выключаем таймер при уничтожении контроллера.
        timer?.invalidate()
    }

    /// Загрузить новый аудио-файл.
    /// - Parameters:
    ///   - url: путь к файлу.
    ///   - autoplay: начинать ли сразу воспроизведение (удобно для Finder-open).
    func loadFile(url: URL, autoplay: Bool) {
        // Сбрасываем текущее состояние перед загрузкой нового файла.
        stop(resetToStart: true)

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            fileURL = url
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            durationSeconds = Double(totalFrames) / sampleRate
            currentTimeSeconds = 0
            lastSeekFrame = 0

            if autoplay {
                // Поведение при открытии из Finder: старт сразу.
                playFromCurrentPosition()
            }
        } catch {
            print("Failed to load audio file: \(error)")
        }
    }

    /// Универсальный toggle для кнопки/Space.
    func togglePlayPause() {
        guard audioFile != nil else { return }
        if isPlaying {
            pause()
        } else {
            playFromCurrentPosition()
        }
    }

    /// Остановить воспроизведение.
    /// - Parameter resetToStart: если true, возвращаем playhead в 0.
    func stop(resetToStart: Bool = true) {
        playerNode.stop()
        isPlaying = false

        if resetToStart {
            lastSeekFrame = 0
            currentTimeSeconds = 0
        } else {
            lastSeekFrame = frameForCurrentPosition()
            currentTimeSeconds = seconds(forFrame: lastSeekFrame)
        }
    }

    /// Перемотка к конкретному времени.
    ///
    /// Механика MVP:
    /// 1) считаем новый стартовый фрейм,
    /// 2) `playerNode.stop()`,
    /// 3) при необходимости снова `scheduleSegment(...)` и `play()`.
    ///
    /// Это простая и стабильная схема для `AVAudioPlayerNode`.
    func seek(seconds: Double, shouldContinuePlaying: Bool? = nil) {
        guard audioFile != nil else { return }

        let wasPlaying = shouldContinuePlaying ?? isPlaying
        let clampedSeconds = max(0, min(seconds, durationSeconds))
        lastSeekFrame = frame(forSeconds: clampedSeconds)
        currentTimeSeconds = clampedSeconds

        playerNode.stop()
        isPlaying = false

        if wasPlaying {
            playFromCurrentPosition()
        }
    }

    /// Относительная перемотка (вперёд/назад на дельту секунд).
    func seekBy(deltaSeconds: Double) {
        seek(seconds: currentTimeSeconds + deltaSeconds)
    }

    /// Переключить loop.
    func toggleLoop() {
        isLoopEnabled.toggle()
    }

    /// Первичная настройка графа `engine -> mainMixer`.
    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    /// Запуск воспроизведения с `lastSeekFrame`.
    ///
    /// Ключевая часть всей архитектуры seek/scrub:
    /// мы каждый раз планируем оставшийся сегмент файла, начиная с нужного фрейма.
    private func playFromCurrentPosition() {
        guard let file = audioFile else { return }
        guard totalFrames > 0 else { return }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Failed to restart engine: \(error)")
            }
        }

        let startFrame = max(0, min(lastSeekFrame, totalFrames))
        let remainingFrames = max(0, totalFrames - startFrame)
        guard remainingFrames > 0 else {
            // Если трек уже в конце и loop включён — перезапускаем с начала.
            if isLoopEnabled {
                lastSeekFrame = 0
                currentTimeSeconds = 0
                playFromCurrentPosition()
            }
            return
        }

        playerNode.stop()
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames),
            at: nil,
            completionHandler: nil
        )
        playerNode.play()
        isPlaying = true
    }

    /// Пауза через `stop()` + запоминание позиции.
    /// Для MVP этого достаточно, чтобы потом возобновить с текущего места.
    private func pause() {
        lastSeekFrame = frameForCurrentPosition()
        currentTimeSeconds = seconds(forFrame: lastSeekFrame)
        playerNode.stop()
        isPlaying = false
    }

    /// Обновление прогресса примерно 20 раз/сек.
    /// Этого достаточно для плавного playhead без лишней нагрузки CPU.
    private func startProgressTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickProgress()
        }
    }

    /// Один «тик» обновления прогресса и проверка достижения конца трека.
    private func tickProgress() {
        guard audioFile != nil else { return }

        let currentFrame = frameForCurrentPosition()
        currentTimeSeconds = seconds(forFrame: currentFrame)

        if isPlaying && currentFrame >= totalFrames {
            if isLoopEnabled {
                lastSeekFrame = 0
                currentTimeSeconds = 0
                playFromCurrentPosition()
            } else {
                // В MVP после достижения конца без loop — стоп и сброс в начало.
                stop(resetToStart: true)
            }
        }
    }

    /// Текущий абсолютный фрейм на основе:
    /// - `lastSeekFrame` (откуда стартовали),
    /// - `sampleTime` внутри текущего schedule.
    private func frameForCurrentPosition() -> AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return lastSeekFrame
        }

        let absolute = lastSeekFrame + AVAudioFramePosition(playerTime.sampleTime)
        return max(0, min(absolute, totalFrames))
    }

    /// Утилита: секунды -> фреймы.
    private func frame(forSeconds seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(seconds * sampleRate)
    }

    /// Утилита: фреймы -> секунды.
    private func seconds(forFrame frame: AVAudioFramePosition) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frame) / sampleRate
    }
}
