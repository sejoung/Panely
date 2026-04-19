import SwiftUI

struct PanelySlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackHeight: CGFloat = 2
    private let thumbSize: CGFloat = 10
    private let hitAreaHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let progress = normalized(value: value, in: geo.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PanelyColor.bgTertiary)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(PanelyColor.accentPrimary)
                    .frame(width: progress, height: trackHeight)

                Circle()
                    .fill(PanelyColor.textPrimary)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: progress - thumbSize / 2)
            }
            .frame(height: hitAreaHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        update(from: gesture.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: hitAreaHeight)
    }

    private func normalized(value: Double, in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span) * width
    }

    private func update(from x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let pct = min(max(x / width, 0), 1)
        value = range.lowerBound + Double(pct) * (range.upperBound - range.lowerBound)
    }
}

#Preview {
    @Previewable @State var value: Double = 3

    return PanelySlider(value: $value, range: 0...10)
        .frame(width: 400)
        .padding(PanelySpacing.xl)
        .background(PanelyColor.bgSecondary)
}
