import SwiftUI

// Note: no @State or other macro-based SwiftUI APIs (the Command Line Tools lack the plugins).

/// Contents of the downloads popover.
struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { manager.clearInactive() }
                    .disabled(manager.items.allSatisfy { $0.state == .downloading })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.items.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item, manager: manager)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadManager.Item
    let manager: DownloadManager

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.state == .downloading {
                Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            } else if item.state == .finished {
                Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { manager.open(item) }
        .help(item.state == .finished ? "Double-click to open" : "")
    }

    private var icon: NSImage {
        if let destination = item.destination, item.state == .finished {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var status: String {
        let received = Self.bytes.string(fromByteCount: item.receivedBytes)
        switch item.state {
        case .downloading:
            guard item.totalBytes > 0 else { return received }
            return "\(received) of \(Self.bytes.string(fromByteCount: item.totalBytes))"
        case .finished:
            return Self.bytes.string(fromByteCount: max(item.totalBytes, item.receivedBytes))
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return "Failed — \(message)"
        }
    }
}
