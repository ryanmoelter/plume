import SwiftUI

/// Linear's logomark, tinted by the surrounding foreground style.
struct LinearLogo: View {
    var size: CGFloat = 12

    var body: some View {
        Image("LinearLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
