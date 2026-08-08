import SwiftUI

enum ClipTimelineMath {
    static func boundaries(for ranges: [AudioTimeRange]) -> [TimeInterval] {
        var cursor: TimeInterval = 0
        var result: [TimeInterval] = [0]
        for range in ranges {
            cursor += max(0, range.end - range.start)
            result.append(cursor)
        }
        return result
    }

    static func snappedTime(
        _ time: TimeInterval,
        duration: TimeInterval,
        boundaries: [TimeInterval],
        trackWidth: CGFloat,
        threshold: CGFloat = 10
    ) -> (time: TimeInterval, boundary: TimeInterval?) {
        let clamped = min(max(time, 0), duration)
        guard duration > 0, trackWidth > 0 else { return (clamped, nil) }
        let secondsPerPixel = duration / trackWidth
        guard let nearest = boundaries.min(by: { abs($0 - clamped) < abs($1 - clamped) }),
              abs(nearest - clamped) <= TimeInterval(threshold) * secondsPerPixel else {
            return (clamped, nil)
        }
        return (nearest, nearest)
    }
}

/// A compact, NLE-style view of the retained source ranges. Clip widths are
/// proportional to their edited duration and every seam is a reversible cut.
struct ClipTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var snappedBoundary: TimeInterval?

    private let trackHeight: CGFloat = 38
    private let rulerHeight: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(model.estimatedEditedDuration, 0.001)
            let boundaries = ClipTimelineMath.boundaries(for: model.timelineClips)
            let progress = CGFloat(min(max(model.timelineCurrentTime / duration, 0), 1))

            ZStack(alignment: .topLeading) {
                ruler(duration: duration, width: width)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PoetTheme.background.opacity(0.72))

                    clips(duration: duration, width: width)

                    playhead(height: trackHeight + 7)
                        .offset(x: progress * width)
                }
                .frame(height: trackHeight)
                .offset(y: rulerHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let result = ClipTimelineMath.snappedTime(
                                TimeInterval(ratio) * duration,
                                duration: duration,
                                boundaries: boundaries,
                                trackWidth: width
                            )
                            snappedBoundary = result.boundary
                            model.seekOnTimeline(to: result.time)
                        }
                        .onEnded { _ in snappedBoundary = nil }
                )
            }
        }
        .frame(minHeight: rulerHeight + trackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edit timeline")
        .accessibilityValue("\(model.timelineClips.count) clips, playhead at \(clock(model.timelineCurrentTime))")
        .help("Drag to scrub. The playhead snaps to clip boundaries.")
    }

    @ViewBuilder
    private func clips(duration: TimeInterval, width: CGFloat) -> some View {
        ForEach(Array(model.timelineClips.enumerated()), id: \.offset) { index, range in
            let editedStart = model.timelineClips.prefix(index).reduce(0) {
                $0 + max(0, $1.end - $1.start)
            }
            let clipDuration = max(0, range.end - range.start)
            let x = CGFloat(editedStart / duration) * width
            let clipWidth = max(1, CGFloat(clipDuration / duration) * width)
            let isActive = model.timelineCurrentTime >= editedStart &&
                (model.timelineCurrentTime < editedStart + clipDuration || index == model.timelineClips.count - 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? PoetTheme.sageDark : PoetTheme.elevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isActive ? PoetTheme.sage.opacity(0.7) : PoetTheme.faint.opacity(0.26), lineWidth: 1)
                    }

                if clipWidth >= 25 {
                    Text("\(index + 1)")
                        .font(PoetTheme.utility(9, weight: .bold))
                        .foregroundStyle(isActive ? PoetTheme.sage : PoetTheme.muted)
                        .padding(.leading, 8)
                }

                if clipWidth >= 92 {
                    Text("\(clock(range.start))–\(clock(range.end))")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(PoetTheme.faint)
                        .padding(.trailing, 7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: max(1, clipWidth - (index == model.timelineClips.count - 1 ? 0 : 3)), height: trackHeight)
            .offset(x: x)
        }
    }

    private func ruler(duration: TimeInterval, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { index in
                let ratio = CGFloat(index) / 4
                VStack(spacing: 2) {
                    Text(clock(duration * TimeInterval(ratio)))
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(PoetTheme.faint)
                    Rectangle().fill(PoetTheme.divider).frame(width: 1, height: 3)
                }
                .fixedSize()
                .offset(x: min(max(ratio * width - (index == 0 ? 0 : 11), 0), max(0, width - 24)))
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .leading)
    }

    private func playhead(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 7))
                .rotationEffect(.degrees(180))
            Rectangle().frame(width: 1.5, height: height - 7)
        }
        .foregroundStyle(snappedBoundary == nil ? PoetTheme.cream : PoetTheme.sage)
        .shadow(color: .black.opacity(0.65), radius: 2)
        .offset(x: -4, y: -5)
        .allowsHitTesting(false)
    }

    private func clock(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
