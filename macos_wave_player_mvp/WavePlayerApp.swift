import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Точка входа приложения (SwiftUI App lifecycle).
///
/// Здесь:
/// - создаём один общий `AudioEngineController`,
/// - подключаем главное окно,
/// - добавляем пункт `File -> Open…`,
/// - связываем NSApplicationDelegate для открытия файла из Finder.
@main
struct WavePlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudioEngineController()

    var body: some Scene {
        WindowGroup {
            PlayerView(controller: controller)
                .frame(minWidth: 700, minHeight: 300)
                .onAppear {
                    // Делегат (AppKit) не знает про SwiftUI-state напрямую,
                    // поэтому пробрасываем controller вручную.
                    appDelegate.controller = controller
                }
        }
        .commands {
            // Новый документ не нужен для MVP-плеера.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("File") {
                Button("Open…") {
                    // По ТЗ: через File/Open autoplay не обязателен.
                    // Здесь фиксируем поведение: без autoplay.
                    openFilePanelAndLoad(autoplay: false)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    /// Показывает стандартный диалог выбора файла и загружает аудио.
    private func openFilePanelAndLoad(autoplay: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            controller.loadFile(url: url, autoplay: autoplay)
        }
    }
}

/// AppKit-делегат для открытия файлов из Finder (`Open With`, двойной клик).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: AudioEngineController?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        // По ТЗ фиксируем поведение: Finder-open -> autoplay включён.
        controller?.loadFile(url: first, autoplay: true)
    }
}
