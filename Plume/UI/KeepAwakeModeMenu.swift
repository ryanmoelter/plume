import SwiftUI

/// A menu rather than a `Picker`, so each mode can show its caption while
/// the menu is open.
struct KeepAwakeModeMenu: View {
    @Binding var selection: KeepAwakeMode

    var body: some View {
        Menu {
            ForEach(KeepAwakeMode.allCases) { mode in
                Toggle(isOn: Binding(
                    get: { selection == mode },
                    set: { if $0 { selection = mode } }
                )) {
                    Text(mode.label)
                    if let caption = mode.caption {
                        Text(caption)
                    }
                }
            }
        } label: {
            Text(selection.label)
        }
        .fixedSize()
        .plumeID(
            AccessibilityID.keepAwakeModePicker,
            value: selection.rawValue,
            setValue: { if let mode = KeepAwakeMode(rawValue: $0) { selection = mode } }
        )
    }
}
