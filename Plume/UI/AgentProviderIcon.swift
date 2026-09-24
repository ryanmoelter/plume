import SwiftUI

struct AgentProviderIcon: View {
    let provider: AgentProviderKind
    var size: CGFloat = 14

    var body: some View {
        Image(provider.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(provider.displayName)
    }
}
