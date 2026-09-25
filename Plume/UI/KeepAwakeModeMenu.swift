import SwiftUI

struct KeepAwakeModeMenu: View {
    @Binding var selection: KeepAwakeMode

    var body: some View {
        Picker(selection: $selection) {
            ForEach(KeepAwakeMode.allCases) { mode in
                VStack(alignment: .leading) {
                    Text(mode.label)
                    if let caption = mode.caption {
                        Text(caption)
                    }
                }
                .tag(mode)
            }
        } label: {
            Text("Keep awake")
        } currentValueLabel: {
            Text(selection.label)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .plumeID(
            AccessibilityID.keepAwakeModePicker,
            value: selection.rawValue,
            setValue: { if let mode = KeepAwakeMode(rawValue: $0) { selection = mode } }
        )
    }
}
