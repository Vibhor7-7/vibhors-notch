import SwiftUI

/// Black notch silhouette: concave flares at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        let topR: CGFloat = vm.isExpanded ? 18 : 6
        let bottomR: CGFloat = vm.isExpanded ? 32 : 10
        let width = vm.isExpanded ? vm.expandedSize.width : vm.notchSize.width + topR * 2
        let height = vm.isExpanded ? vm.expandedSize.height : vm.notchSize.height
        let shape = NotchShape(topRadius: topR, bottomRadius: bottomR)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0), radius: 14, y: 6)

            if vm.isExpanded {
                ExpandedView()
                    .padding(.horizontal, topR)
                    .frame(width: vm.expandedSize.width, height: vm.expandedSize.height)
                    .frame(width: width, height: height, alignment: .top)
                    .clipShape(shape)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

struct ExpandedView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch vm.tab {
                case .home: HomeView()
                case .notes: NotesView()
                case .shelf: ShelfView()
                case .prompter: PrompterView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }

    /// Tabs on the left ear, controls on the right ear, camera in the middle.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { vm.tab = tab }
                    } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.white.opacity(vm.tab == tab ? 0.16 : 0))
                            )
                            .foregroundStyle(vm.tab == tab ? .white : .white.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: vm.notchSize.width)

            HStack(spacing: 6) {
                Button {
                    vm.isPinned.toggle()
                } label: {
                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(vm.isPinned ? .white : .white.opacity(0.55))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.isPinned ? "Unpin (allow auto-close)" : "Pin open")

                Menu {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { vm.launchAtLogin = $0 }
                    ))
                    Divider()
                    Button("Quit Vibhor's Notch") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: max(vm.notchSize.height, 30))
    }
}

/// Small rounded icon button used throughout the notch.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.09))
            )
            .contentShape(Rectangle())
    }
}

/// Text pill button (e.g. "Start", "Clear").
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(
                Capsule().fill(prominent
                               ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.95)
                               : Color.white.opacity(configuration.isPressed ? 0.22 : 0.1))
            )
            .contentShape(Capsule())
    }
}
