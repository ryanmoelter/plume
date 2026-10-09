import SwiftUI

struct DeviceTabHost: View {
    let tab: TaskTab
    let isVisible: Bool

    @State private var session: EmulatorSession?

    var body: some View {
        Group {
            if isVisible, let session {
                if session.state == .needsDevice {
                    EmulatorPickerView(onAttach: session.attach, onBoot: session.boot)
                } else {
                    EmulatorDeviceView(session: session)
                }
            } else {
                Color.clear
            }
        }
        .onAppear(perform: makeSession)
    }

    private func makeSession() {
        guard session == nil else { return }
        let session = EmulatorSessionManager.shared.session(
            for: tab.id,
            avdID: tab.deviceIdentifier,
            displayName: tab.deviceIdentifier == nil ? nil : tab.title
        )
        session.onDeviceChange = { [tab] avdID, displayName in
            tab.deviceIdentifier = avdID
            tab.title = displayName
        }
        session.start()
        self.session = session
    }
}
