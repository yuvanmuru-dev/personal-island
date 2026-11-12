import AppKit
import SwiftUI
import PersonalIslandCore

struct IslandView: View {
    @ObservedObject var coordinator: IslandCoordinator
    @ObservedObject var presentation: IslandPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if presentation.isExpanded {
                expandedContent
            } else {
                compactContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if presentation.layout.hasNotch {
                if presentation.isExpanded {
                    NotchShape(topCornerRadius: 6, bottomCornerRadius: 22)
                        .fill(.black)
                } else {
                    // The compact window is the camera housing itself. Paint
                    // nothing visible: square black corners would show beside
                    // the housing's rounded bottom corners.
                    Rectangle().fill(.black.opacity(0.01))
                }
            } else {
                RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                    .fill(.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                    }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onExitCommand { presentation.collapse() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: presentation.isExpanded)
    }

    private var backgroundCornerRadius: CGFloat {
        presentation.isExpanded ? 24 : presentation.layout.compactSize.height / 2
    }

    private var compactContent: some View {
        Button {
            presentation.toggle()
        } label: {
            Group {
                if presentation.layout.hasNotch {
                    // Under the camera housing there are no pixels to show
                    // content; the compact island is only a hover/click target.
                    Color.clear
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 11, weight: .medium))
                        Text("\(coordinator.shelfItemCount)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open shelf, \(coordinator.shelfItemCount) items")
        .help("Open shelf")
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "tray.fill")
                    .foregroundStyle(.white.opacity(0.72))
                Text("Shelf")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(coordinator.shelfItemCount)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                if !coordinator.shelfItems.isEmpty {
                    headerButton("trash", label: "Clear shelf") { coordinator.clearShelf() }
                }
                headerButton("camera.viewfinder", label: "Capture region (\(coordinator.captureShortcutName))") {
                    presentation.collapse()
                    coordinator.captureRegion()
                }
                .disabled(coordinator.isCapturing)
                Button {
                    presentation.collapse()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close shelf")
                .help("Close shelf")
            }

            shelfContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = coordinator.shelfMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }

            HStack {
                Text("PREVIEW")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.38))
                Spacer()
                Button("Settings") { coordinator.showSettings() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, presentation.layout.topContentInset + 12)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var shelfContent: some View {
        if coordinator.shelfAvailability == .unavailable {
            VStack(spacing: 9) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Temporary shelf unavailable")
                    .font(.system(size: 13, weight: .medium))
                Button("Try again") { coordinator.prepareShelfIfNeeded(retry: true) }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
            }
        } else if coordinator.shelfItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.36))
                Text("Your shelf is empty")
                    .font(.system(size: 13, weight: .medium))
                Text("Press \(coordinator.captureShortcutName) or the camera button to capture a region.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(coordinator.shelfItems, id: \.id) { item in
                        ShelfTile(
                            item: item,
                            thumbnail: coordinator.thumbnails[item.id],
                            symbol: symbol(for: item),
                            label: label(for: item),
                            onCopy: { coordinator.copyShelfItem(item.id) },
                            onRemove: { coordinator.removeShelfItem(item.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func symbol(for item: ShelfItem) -> String {
        switch item.payload {
        case .screenshot: "photo"
        case .fileReference: "doc"
        }
    }

    private func label(for item: ShelfItem) -> String {
        switch item.payload {
        case .screenshot: "Screenshot"
        case .fileReference: "File"
        }
    }
}

/// One shelf item: thumbnail, capture time, and Copy/Remove on hover. The
/// controls stay reachable by keyboard and accessibility without hovering.
private struct ShelfTile: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let symbol: String
    let label: String
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .light))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 96, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }

                HStack(spacing: 4) {
                    tileButton("doc.on.doc", label: "Copy \(label.lowercased())", action: onCopy)
                    tileButton("xmark", label: "Remove \(label.lowercased())", action: onRemove)
                }
                .padding(4)
                .opacity(hovering ? 1 : 0)
            }
            Text(item.createdAt, style: .time)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func tileButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
