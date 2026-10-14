import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var reader: ReaderModel
    @State private var isImporterPresented = false

    var body: some View {
        Group {
            if reader.isLoading {
                ProgressView("PDF açılıyor…")
                    .controlSize(.large)
            } else if reader.document == nil {
                emptyState
            } else {
                ReaderView(openPDF: { isImporterPresented = true })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if reader.document == nil && !reader.isLoading {
                ZStack {
                    HStack {
                        Text("Sürüm \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    githubLink
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
            reader.open(url)
            return true
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .alert("İşlem Tamamlanamadı", isPresented: errorBinding) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(reader.errorMessage ?? "Bilinmeyen hata")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Color.accentColor)

            Text("pdf/voice")
                .font(.largeTitle.weight(.semibold))

            Text("Belgelerini dinle. Kaldığın yerden devam et.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button("PDF Seç") {
                isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            Text("PDF'yi bu pencereye de sürükleyebilirsin.")
                .font(.callout)
                .foregroundStyle(.tertiary)

                if !reader.recentDocuments.isEmpty {
                    Divider().frame(width: 320).padding(.vertical, 6)
                    HStack {
                        Text("Son Kullanılanlar")
                            .font(.headline)
                        Spacer()
                        Button("Temizle", role: .destructive) {
                            reader.clearRecentDocuments()
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(width: 320)
                    ForEach(reader.recentDocuments) { document in
                        Button {
                            reader.openRecent(document)
                        } label: {
                            Label(document.name, systemImage: "clock.arrow.circlepath")
                                .frame(width: 300, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
        .padding(40)
    }

    private var githubLink: some View {
        Link(destination: URL(string: "https://github.com/tioxs/pdf-to-voice")!) {
            Label("\"R\" made for it", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.link)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { reader.errorMessage != nil },
            set: { if !$0 { reader.errorMessage = nil } }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let URLs):
            guard let URL = URLs.first else { return }
            reader.open(URL)
        case .failure(let error):
            reader.errorMessage = error.localizedDescription
        }
    }
}
