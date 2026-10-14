import SwiftUI

@main
struct PDFToVoiceApp: App {
    @StateObject private var reader = ReaderModel()

    var body: some Scene {
        Window("pdf/voice", id: "reader") {
            ContentView()
                .environmentObject(reader)
                .frame(minWidth: 980, minHeight: 640)
                .onOpenURL { reader.open($0) }
        }
        .windowStyle(.titleBar)
    }
}
