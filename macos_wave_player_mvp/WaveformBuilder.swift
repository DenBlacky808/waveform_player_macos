import AVFAudio
import Foundation

/// Построение упрощённого waveform-представления (peak envelope).
///
/// Идея: вместо рисования миллионов сэмплов строим ограниченный массив пиков,
/// который быстро рисуется в Canvas. Для UI это почти всегда достаточно.
enum WaveformBuilder {
    /// Читает файл и возвращает пики для визуализации waveform.
    ///
    /// - Parameters:
    ///   - url: аудио-файл.
    ///   - targetSamples: желаемое число «столбиков» waveform.
    ///   - maxDurationSeconds: защитный лимит длительности анализа для MVP.
    /// - Returns: массив нормализованных пиков [0...1].
    static func buildPeaks(from url: URL, targetSamples: Int = 3000, maxDurationSeconds: Double = 3600) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)

        // Чтобы не съесть слишком много памяти на огромных файлах,
        // ограничиваем максимум анализируемых фреймов.
        let maxFrames = AVAudioFramePosition(maxDurationSeconds * sampleRate)
        let framesToRead = min(file.length, maxFrames)
        guard framesToRead > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(framesToRead)
        ) else {
            return []
        }

        try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        // Ограничиваем количество столбиков сверху, чтобы Canvas оставался быстрым.
        let bucketCount = max(200, min(targetSamples, 6000))
        // Сколько исходных сэмплов попадает в один «пик-бакет».
        let bucketSize = max(1, frameLength / bucketCount)
        var peaks = Array(repeating: Float(0), count: bucketCount)

        guard let channelData = buffer.floatChannelData else { return [] }

        // Для каждого бакета берём максимальную амплитуду.
        // Это классический и дешёвый вариант peak envelope.
        for bucket in 0..<bucketCount {
            let start = bucket * bucketSize
            let end = min(frameLength, start + bucketSize)
            var peak: Float = 0

            if start >= end {
                peaks[bucket] = 0
                continue
            }

            for frame in start..<end {
                // Сводим многоканальный сигнал к одному значению:
                // берём максимум abs(...) среди каналов.
                var monoAbs: Float = 0
                for channel in 0..<channels {
                    monoAbs = max(monoAbs, abs(channelData[channel][frame]))
                }
                peak = max(peak, monoAbs)
            }

            // Нормализованный диапазон для предсказуемой отрисовки.
            peaks[bucket] = min(max(peak, 0), 1)
        }

        return peaks
    }
}
