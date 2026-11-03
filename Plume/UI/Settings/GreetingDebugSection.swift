#if DEBUG
import SwiftUI

/// Forces the Home greeting, to check each one's glyph without waiting for
/// the clock.
struct GreetingDebugSection: View {
    @AppStorage(HomeGreeting.debugOverrideKey) private var override = ""

    var body: some View {
        Section {
            TimelineView(.everyMinute) { context in
                Picker("Home greeting", selection: $override) {
                    Text("Automatic (\(HomeGreeting(date: context.date).name))").tag("")
                    ForEach(HomeGreeting.allCases, id: \.self) { greeting in
                        Text("\(greeting.name) (\(greeting.hoursText))").tag(greeting.rawValue)
                    }
                }
                .plumeID(AccessibilityID.debugGreetingOverridePicker, value: override.isEmpty ? "automatic" : override)
            }
        } header: {
            Text("Home (Debug)")
        }
    }
}
#endif
