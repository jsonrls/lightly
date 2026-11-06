import SwiftUI
import CleanerCore

@main
struct MacCleanerApp: App {
  @State private var model: AppModel

  init() {
    if Launch.isDryRunReport { runDryRunReport() }
    NSLog("Mac Cleaner mode: %@", "\(Launch.mode)")
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
        Image(systemName: "sparkles")
        Text(text)
      }
      .accessibilityLabel("Mac Cleaner, \(text)")
    }
    .menuBarExtraStyle(.window)

    Window("Mac Cleaner", id: "full") {
      FullView(model: model)
        .windowFullScreenBehavior(.disabled)
    }
    .defaultSize(width: 760, height: 480)
    .windowResizability(.contentSize)
  }
}
