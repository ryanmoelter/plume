import SwiftUI

/// The fold postures of a device with a hinge, as one toolbar button each. Shows nothing for a device without one.
struct DeviceFoldControls: View {
    let session: DeviceSession
    var vertical = false

    var body: some View {
        if !session.postures.isEmpty {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            layout {
                ForEach(session.postures, id: \.self) { posture in
                    button(for: posture)
                }
                if vertical {
                    Divider().frame(width: 14).padding(.vertical, 4)
                } else {
                    Divider().frame(height: 14).padding(.horizontal, 4)
                }
            }
        }
    }

    private func button(for posture: DevicePosture) -> some View {
        let selected = session.posture == posture
        let action = { session.setPosture(posture) }
        return Button(action: action) {
            Image(systemName: posture.symbol)
                .frame(width: 24, height: 22)
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.borderless)
        .help(posture.title)
        .accessibilityLabel(posture.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .plumeID(AccessibilityID.deviceFoldPostureButton, label: posture.title, value: selected ? "selected" : nil, invoke: action)
    }
}

extension DevicePosture {
    var title: String {
        switch self {
        case .closed: "Closed"
        case .halfOpen: "Half-Open"
        case .open: "Open"
        }
    }

    var symbol: String {
        switch self {
        case .closed: "book.closed"
        case .halfOpen: "laptopcomputer"
        case .open: "book"
        }
    }
}
