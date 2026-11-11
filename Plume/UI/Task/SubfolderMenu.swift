import AppKit
import SwiftUI

/// The subfolder dropdown's menu, shared by the new conversation screen and
/// Home's composer: the project root, the checkout's top-level folders, and a
/// panel for anything else.
struct SubfolderMenuItems: View {
    let choices: [String]
    /// Where the panel opens.
    let checkoutRoot: String?
    let choose: (String?) -> Void
    /// Takes the panel's path, which may lie outside the checkout.
    let chooseFolder: (String) -> Void

    var body: some View {
        Button("Choose Folder…", action: runPanel)
        Divider()
        Button(ProjectSubfolder.rootTitle) { choose(nil) }
        ForEach(choices, id: \.self) { name in
            Button(name) { choose(name) }
        }
    }

    private func runPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = checkoutRoot.map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chooseFolder(url.path)
    }
}

/// What leads a dropdown's label. The subfolder dropdown leads with the path
/// separator, so the project and the subfolder read as one path.
enum MenuLabelGlyph {
    case symbol(String)
    case pathSeparator

    @ViewBuilder
    var view: some View {
        switch self {
        case .symbol(let name): Image(systemName: name)
        case .pathSeparator: Text("/")
        }
    }
}

extension ProjectSubfolder {
    /// The subfolder dropdown steps two sizes down the type scale at the
    /// project root, where it is the default nobody chose.
    static func labelStyle(_ style: Typography.Style, subfolder: String?) -> Typography.Style {
        subfolder == nil ? style.stepped(-2) : style
    }
}
