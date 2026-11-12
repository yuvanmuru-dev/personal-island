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
                NotchShape(topCornerRadius: 6, bottomCornerRadius: presentation.isExpanded ? 22 : 14)
                    .fill(.black)
            } else {
                RoundedRectangle(cornerRadius: presentation.isExpanded ? 24 : 17, style: .continuous)
                    .fill(.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: presentation.isExpanded ? 24 : 17, style: .continuous)
                            .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                    }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onExitCommand { presentation.collapse() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: presentation.isExpanded)
    }

    private var compactContent: some View {
        Button {
            presentation.toggle()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "tray")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28)
                Text("Shelf")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.leading, 5)
                Spacer(minLength: 10)
                Text("\(coordinator.shelfItemCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 24)
            }
            .padding(.horizontal, 10)
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
        .padding(.top, 12)
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
                Text("Capture and dragging are coming next.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(coordinator.shelfItems, id: \.id) { item in
                        VStack(spacing: 8) {
                            Image(systemName: symbol(for: item))
                                .font(.system(size: 26, weight: .light))
                            Text(label(for: item))
                                .font(.system(size: 10))
                        }
                        .frame(width: 80, height: 88)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
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
