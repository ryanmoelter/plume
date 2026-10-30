import SwiftUI

struct DeviceTabHost: View {
    let tab: TaskTab
    let isVisible: Bool

    @State private var session: DeviceSession?

    var body: some View {
        Group {
            if isVisible, let session {
                if session.state == .needsDevice {
                    DevicePickerView(
                        onConnect: session.attach,
                        onAttach: session.attach,
                        onBoot: session.boot,
                        onReserve: session.reserve
                    )
                } else {
                    AndroidDeviceView(session: session)
                }
            } else {
                Color.clear
            }
        }
        .onAppear(perform: makeSession)
    }

    private func makeSession() {
        guard session == nil else { return }
        session = DeviceSessionManager.shared.prepareSession(for: tab)
    }
}
