import SwiftUI

// Modern rotating-arc spinner (replaces the dated petal/spoke UIActivityIndicator look).
struct Spinner: View {
    var size: CGFloat = 26
    var color: Color = .white
    var lineWidth: CGFloat = 2.5
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
