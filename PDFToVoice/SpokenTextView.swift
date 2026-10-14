import AppKit
import SwiftUI
import PDFKit

struct SpokenTextView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let spokenRange: NSRange?
    let fontSize: Double
    var readFrom: (Int) -> Void = { _ in }

    final class Coordinator {
        var text = ""
        var size = 0.0
        var scheme: ColorScheme?
        var highlighted: NSRange?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let view = ReadingTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 48, height: 36)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ReadingTextView, let storage = view.textStorage else { return }
        view.readFrom = readFrom
        let state = context.coordinator
        let normal = NSFontManager.shared.convert(NSFont.systemFont(ofSize: fontSize), toHaveTrait: .italicFontMask)
        let bold = NSFontManager.shared.convert(normal, toHaveTrait: .boldFontMask)
        let rebuild = state.text != text || state.size != fontSize || state.scheme != colorScheme
        storage.beginEditing()
        if rebuild {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7; paragraph.paragraphSpacing = 12
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: normal, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
            state.text = text; state.size = fontSize; state.scheme = colorScheme; state.highlighted = nil
        } else if let old = state.highlighted, NSMaxRange(old) <= storage.length {
            storage.addAttribute(.font, value: normal, range: old)
            storage.removeAttribute(.backgroundColor, range: old)
        }
        if let range = spokenRange, range.location >= 0, NSMaxRange(range) <= storage.length {
            storage.addAttributes([.font: bold, .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.22)], range: range)
            state.highlighted = range
        } else { state.highlighted = nil }
        storage.endEditing()
        if let range = state.highlighted { view.scrollRangeToVisible(range) }
    }
}

final class ReadingTextView: NSTextView {
    var readFrom: (Int) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Double-click selects a whole word; ordinary selection/copy stays available.
        if event.clickCount == 2, selectedRange().length > 0 { readFrom(selectedRange().location) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Buradan Oku", action: #selector(startReadingSelection), keyEquivalent: "")
        item.target = self; menu.insertItem(item, at: 0)
        return menu
    }
    @objc private func startReadingSelection() { readFrom(selectedRange().location) }
}

struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let spokenRange: NSRange?
    let selectPage: (Int) -> Void
    final class Coordinator {
        var parent: PDFPageView
        var observer: NSObjectProtocol?
        init(_ parent: PDFPageView) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePage
        view.backgroundColor = .windowBackgroundColor
        let coordinator = context.coordinator
        coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak coordinator] _ in
            Task { @MainActor in
                guard let view, let coordinator, view.document === coordinator.parent.document,
                      let page = view.currentPage else { return }
                coordinator.parent.selectPage(coordinator.parent.document.index(for: page))
            }
        }
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document }
        guard let page = document.page(at: pageIndex) else { return }
        if view.currentPage !== page { view.go(to: page) }
        if let range = spokenRange, let selection = page.selection(for: range) {
            selection.color = .controlAccentColor
            view.highlightedSelections = [selection]
        } else { view.highlightedSelections = [] }
    }
}
