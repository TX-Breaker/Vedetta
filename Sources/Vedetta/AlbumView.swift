import SwiftUI
import QuickLook
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import VedettaCore
import VedettaL10n

struct AlbumItem: Identifiable, Hashable {
    var url: URL
    var date: Date
    var isVideo: Bool
    var size: Int64
    var id: URL { url }
}

struct AlbumView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("Everything")
            case .photos: return L("Snapshots")
            case .videos: return L("Videos")
            }
        }
    }
    @Environment(AppModel.self) private var model
    @State private var items: [AlbumItem] = []
    @State private var kind: Kind = .all
    @State private var preview: URL?
    @State private var selection: URL?

    var body: some View {
        let shown = items.filter { kind == .all || (kind == .videos) == $0.isVideo }
        Group {
            if shown.isEmpty {
                EmptyStateView(symbol: "photo.on.rectangle.angled", title: L("The album is empty"),
                               message: L("Snapshots and videos you save from the cameras appear here."))
            } else {
                grid(shown)
            }
        }
        .quickLookPreview($preview, in: shown.map(\.url))
        .navigationTitle(L("Album"))
        .toolbar {
            ToolbarItem(placement: .navigation) { Text(L("Album")).font(.headline).padding(.horizontal, 6) }
            ToolbarItem(placement: .principal) {
                Picker(L("Type"), selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { NSWorkspace.shared.open(model.settings.snapshotsURL) } label: { Label(L("Snapshots folder"), systemImage: "photo") }
                Button { NSWorkspace.shared.open(model.settings.recordingsURL) } label: { Label(L("Videos folder"), systemImage: "film") }
                Button { reload() } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            }
        }
        .onAppear(perform: reload)
        .onKeyPress(.space) {
            if let selection { preview = selection; return .handled }
            return .ignored
        }
    }

    private func grid(_ shown: [AlbumItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(shown) { item in tile(item) }
            }
            .padding(20)
        }
    }

    private func tile(_ item: AlbumItem) -> some View {
        AlbumTile(item: item, selected: selection == item.url)
            .onTapGesture(count: 2) { preview = item.url }
            .onTapGesture { selection = item.url }
            .contextMenu {
                Button(L("Open")) { NSWorkspace.shared.open(item.url) }
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                ShareLink(item: item.url) { Text(L("Share…")) }
                Divider()
                Button(L("Move to Trash"), role: .destructive) { trash(item) }
            }
    }

    private func reload() {
        let folders = [model.settings.snapshotsURL, model.settings.recordingsURL, model.settings.exportsURL]
        Task.detached {
            var found: [AlbumItem] = []
            let fm = FileManager.default
            for folder in Set(folders) {
                guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
                for u in urls {
                    let ext = u.pathExtension.lowercased()
                    guard ["jpg", "jpeg", "png", "mp4", "mov"].contains(ext) else { continue }
                    let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    found.append(AlbumItem(url: u, date: v?.contentModificationDate ?? .distantPast,
                                           isVideo: ext == "mp4" || ext == "mov", size: Int64(v?.fileSize ?? 0)))
                }
            }
            found.sort { $0.date > $1.date }
            await MainActor.run { items = found }
        }
    }

    private func trash(_ item: AlbumItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in
            DispatchQueue.main.async { reload() }
        }
    }
}

struct AlbumTile: View {
    let item: AlbumItem
    var selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.clear, in: .circle)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.deletingPathExtension().lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("\(Format.dateTime.string(from: item.date)) · \(Format.bytes(item.size))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.25)) : .regular, in: .rect(cornerRadius: 18))
        .task(id: item.url) { await loadThumb() }
    }

    private func loadThumb() async {
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 400, height: 225),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            thumb = rep.nsImage
        }
    }
}
