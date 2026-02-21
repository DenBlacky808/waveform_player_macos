# macOS Wave Player MVP (обучающий вариант)

Минимально рабочий Snapper-подобный плеер для macOS на **SwiftUI + AVFAudio**, но с подробными комментариями в коде, чтобы можно было изучать проект «с нуля».

---

## 1) Что делает приложение

- Одно окно:
  - сверху waveform + playhead,
  - снизу кнопки `Play/Pause`, `Stop`, `Loop`.
- Перемотка:
  - клик по waveform — переход в точку,
  - drag по waveform — scrub (частая перемотка во время движения).
- Хоткеи:
  - `Space` — Play/Pause
  - `S` — Stop (в начало)
  - `L` — Loop toggle
  - `← / →` — -1 / +1 сек
  - `Shift + ← / →` — -5 / +5 сек
  - `Home` — в начало
- Открытие файлов:
  - через `File -> Open…` — **без autoplay**;
  - через Finder (`Open With`, двойной клик) — **с autoplay**.

---

## 2) Как устроен проект

- `WavePlayerApp.swift`
  - точка входа SwiftUI-приложения;
  - меню `File -> Open…`;
  - интеграция с Finder через `NSApplicationDelegate.application(_:open:)`.

- `AudioEngineController.swift`
  - вся аудио-логика;
  - `AVAudioEngine + AVAudioPlayerNode`;
  - загрузка файла, play/pause/stop/seek, loop, таймер прогресса.

- `WaveformBuilder.swift`
  - читает аудиофайл;
  - считает peak envelope (массив пиков);
  - ограничивает объём анализа для стабильности MVP.

- `PlayerView.swift`
  - UI на SwiftUI;
  - waveform рендерится через `Canvas`;
  - playhead + жесты scrub;
  - обработка hotkeys (включая стрелки/Home).

---

## 3) Ключевая идея seek в AVAudioPlayerNode

В `AVAudioPlayerNode` удобно реализовать перемотку через **перепланирование сегмента**:

1. Остановить ноду (`playerNode.stop()`).
2. Посчитать `startingFrame` из секунд.
3. Вызвать `scheduleSegment(file, startingFrame, frameCount, at: nil)`.
4. Если нужно продолжать играть — `playerNode.play()`.

Именно эта схема используется в `AudioEngineController`.

---

## 4) Как собирается waveform

Для быстрых UI-отрисовок не рисуем каждый сэмпл файла:

1. Читаем аудио в `AVAudioPCMBuffer`.
2. Делим на бакеты (например, ~3000).
3. Для каждого бакета берём `max(abs(sample))`.
4. Получаем массив `peaks`, который рисуем как вертикальные линии.

Это дешёвый и практичный подход для MVP (не sample-accurate редактор).

---

## 5) Сборка в Xcode

1. Создайте новый **macOS App** (SwiftUI lifecycle).
2. Добавьте 4 `.swift` файла в target.
3. Поставьте macOS target (например, 13+ или актуальный).
4. Build & Run.

---

## 6) Finder integration (Document Types)

Чтобы аудио-файлы открывались через Finder (`Open With`):

### Вариант через Xcode Target -> Info
- **Document Types**
  - Name: `Audio`
  - Role: `Viewer`
  - Content Types: `public.audio`

### Эквивалент в `Info.plist`

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Audio</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.audio</string>
    </array>
  </dict>
</array>
```

---

## 7) Ограничения MVP

- Нет плейлистов, библиотек, тегов, эффектов и спектра.
- Waveform — peak envelope (визуально быстро, но не редактор «по сэмплам»).
- Для простоты стоит ограничение анализа waveform до 1 часа (`maxDurationSeconds = 3600`).
- Нет сложной архитектуры (по задаче специально сделано максимально просто).

---

## 8) Куда развивать дальше

- Чанковое чтение очень больших файлов.
- Более аккуратный debounce при resize окна с пересчётом peaks.
- Range-loop (A/B loop), масштаб waveform (zoom), маркеры.
- Устойчивый слой логирования/ошибок для production-сценариев.
