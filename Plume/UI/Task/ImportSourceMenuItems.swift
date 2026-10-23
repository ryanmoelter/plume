import SwiftUI

/// One item per import source, shared by the File menu and the sidebar's empty state.
struct ImportSourceMenuItems: View {
    let perform: (ImportSource) -> Void

    var body: some View {
        ForEach(ImportSource.allCases) { source in
            Button(source.displayName) { perform(source) }
                .plumeID(AccessibilityID.importSourceItem, label: source.displayName, invoke: { perform(source) })
        }
    }
}
