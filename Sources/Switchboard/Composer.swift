import AppKit
import SwiftUI
import SwitchboardCore
import UniformTypeIdentifiers

/// Images attached to a message. Hooks can only carry text, so each image is saved here and Claude opens it by path.
enum ChatAttachments {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard/attachments", isDirectory: true)
    }

    /// Saves in a format Claude can read, converting anything else (HEIC, TIFF screenshots) to PNG.
    static func save(_ data: Data) -> URL? {
        var bytes = data
        var ext = fileExtension(of: data)
        if ext == nil {
            guard let tiff = NSImage(data: data)?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
            ext = "png"
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext!)")
            try bytes.write(to: url)
            return url
        } catch {
            NSLog("Switchboard: could not save attachment: %@", error.localizedDescription)
            return nil
        }
    }

    private static func fileExtension(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if head.count == 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8...]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return nil
    }
}

/// The dashboard's message box: text and images for one session.
struct ChatComposer: View {
    let session: Session
    @ObservedObject var store: SessionStore
    @State private var text = ""
    @State private var images: [URL] = []
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty || !images.isEmpty }
    private var canReceive: Bool { store.replyable.contains(session.id) }
    private var queued: String? { store.queued[session.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let queued {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Summarizer.oneLine(queued, max: 90)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Cancel") { store.cancelQueued(session.id) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
            }
            if !images.isEmpty { thumbnails }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseImages) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach images (or drop or paste them here)")
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Return). Option-Return adds a line.")
            }
            if !canReceive && session.status == .review {
                Text("Claude isn't listening for messages here. Send one message in its terminal to reconnect; this will go out after that turn.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(dropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .onAppear(perform: watchPaste)
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    private var placeholder: String {
        canReceive ? "Message Claude…" : "Message Claude (sends when this turn ends)…"
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Color.secondary
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Button {
                            images.removeAll { $0 == url }
                            try? FileManager.default.removeItem(at: url)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                    }
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        store.send(session.id, ChatMessage.compose(text: trimmed, imagePaths: images.map(\.path)))
        text = ""
        images = []
    }

    private func add(_ data: Data) {
        guard let url = ChatAttachments.save(data) else { return }
        images.append(url)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let data = try? Data(contentsOf: url) { add(data) } }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
                    DispatchQueue.main.async { add(data) }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { add(data) }
                }
            }
        }
        return true
    }

    /// The text field handles ⌘V itself and ignores images, so catch those before it sees them.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v", event.window?.isKeyWindow == true else { return event }
            let board = NSPasteboard.general
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let fileImages = files.compactMap { try? Data(contentsOf: $0) }.filter { NSImage(data: $0) != nil }
            if !fileImages.isEmpty {
                fileImages.forEach(add)
                return nil
            }
            guard board.string(forType: .string) == nil,
                  let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return event }
            add(data)
            return nil
        }
    }
}
