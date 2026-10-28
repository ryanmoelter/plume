import SwiftUI

struct DeviceTabHost: View {
    let tab: TaskTab
    let isVisible: Bool

    @State private var session: DeviceSession?

    var body: some View {
        Group {
            if isVisible, let session {
                if session.state == .needsDevice {
                    DevicePickerView(onConnect: session.attach, onAttach: session.attach, onBoot: session.boot)
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
        let target = tab.deviceTarget
        let session = DeviceSessionManager.shared.session(
            for: tab.id,
            target: target,
            displayName: target == nil ? nil : tab.title
        )
        session.onDeviceChange = { [tab] target, displayName in
            tab.setDevice(target, displayName: displayName)
        }
        session.start()
        self.session = session
    }
}
