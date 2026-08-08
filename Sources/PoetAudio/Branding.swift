import SwiftUI

enum PoeditcalBrand {
    static let name = "Poeditcal"
}

/// The supplied Poeditcal mark, kept as a native SwiftUI path so it stays crisp
/// and can inherit the app's sage/cream palette at every size.
struct PoeditcalMark: View {
    var color: Color = PoetTheme.sage

    var body: some View {
        PoeditcalMarkShape()
            .fill(color)
            .aspectRatio(439.0 / 774.0, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct PoeditcalWordmark: View {
    var color: Color = PoetTheme.cream
    var markColor: Color = PoetTheme.sage

    var body: some View {
        HStack(spacing: 9) {
            PoeditcalMark(color: markColor)
                .frame(width: 11, height: 20)
            Text(PoeditcalBrand.name.uppercased())
                .font(PoetTheme.utility(15, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PoeditcalBrand.name)
    }
}

private struct PoeditcalMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let minX = 596.93
        let maxX = 617.98
        let minY = 813.002
        let maxY = 824.952

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat((y - minY) / (maxY - minY)) * rect.width,
                y: rect.minY + CGFloat((maxX - x) / (maxX - minX)) * rect.height
            )
        }

        var path = Path()
        path.move(to: point(607.455, 824.952))
        path.addLine(to: point(601.38, 813.002))
        path.addLine(to: point(613.53, 813.002))
        path.closeSubpath()

        path.move(to: point(614.705, 813.002))
        path.addLine(to: point(617.78, 813.002))
        path.addCurve(to: point(617.98, 814.152), control1: point(617.847, 813.169), control2: point(617.98, 813.752))
        path.addCurve(to: point(614.68, 816.852), control1: point(617.98, 815.602), control2: point(616.522, 816.852))
        path.addLine(to: point(612.891, 816.852))
        path.addLine(to: point(614.578, 813.534))
        path.addCurve(to: point(614.705, 813.002), control1: point(614.663, 813.367), control2: point(614.705, 813.184))
        path.closeSubpath()

        path.move(to: point(610.782, 821.002))
        path.addLine(to: point(616.78, 821.002))
        path.addCurve(to: point(616.98, 822.102), control1: point(616.847, 821.169), control2: point(616.98, 821.935))
        path.addCurve(to: point(613.68, 824.952), control1: point(616.98, 823.66), control2: point(615.522, 824.952))
        path.addLine(to: point(608.773, 824.952))
        path.closeSubpath()

        path.move(to: point(606.137, 824.952))
        path.addLine(to: point(597.08, 824.952))
        path.addCurve(to: point(596.93, 824.002), control1: point(597.013, 824.752), control2: point(596.93, 824.102))
        path.addCurve(to: point(599.88, 821.002), control1: point(596.93, 822.377), control2: point(598.305, 821.002))
        path.addLine(to: point(604.129, 821.002))
        path.closeSubpath()

        path.move(to: point(602.019, 816.852))
        path.addLine(to: point(598.08, 816.852))
        path.addCurve(to: point(597.93, 815.852), control1: point(598.013, 816.685), control2: point(597.93, 816.019))
        path.addCurve(to: point(600.206, 813.06), control1: point(597.93, 814.294), control2: point(599.639, 813.162))
        path.addCurve(to: point(600.332, 813.534), control1: point(600.214, 813.222), control2: point(600.256, 813.384))
        path.closeSubpath()

        return path
    }
}
