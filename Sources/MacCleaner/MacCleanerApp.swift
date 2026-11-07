import SwiftUI
import CleanerCore

@main
struct MacCleanerApp: App {
  @State private var model: AppModel

  /// A template image: macOS shows it white on a dark menu bar and dark on a light one.
  private let menuBarIcon: NSImage? = {
    guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
          let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
  }()

  init() {
    if Launch.isDryRunReport { runDryRunReport() }
    NSLog("Lightly mode: %@", "\(Launch.mode)")
    let model = AppModel(mode: Launch.mode)
    model.start()  // here, not onAppear: window content is only built on the first click
    _model = State(initialValue: model)
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverView(model: model)
    } label: {
      let text = Format.menuBarText(freeBytes: model.stats.diskFreeBytes, memoryFraction: model.stats.memoryUsedFraction)
      HStack {
        if let menuBarIcon { Image(nsImage: menuBarIcon) } else { Image(systemName: "sparkles") }
        Text(text)
      }
      .accessibilityLabel("Lightly, \(text)")
    }
    .menuBarExtraStyle(.window)

    Window("Lightly", id: "full") {
      FullView(model: model)
        .windowFullScreenBehavior(.disabled)
    }
    .defaultSize(width: 760, height: 480)
    .windowResizability(.contentSize)

    Window("Lightly Settings", id: "settings") {
      SettingsView(model: model)
        .windowFullScreenBehavior(.disabled)
    }
    .defaultSize(width: 440, height: 680)
    .windowResizability(.contentMinSize)
  }
}
