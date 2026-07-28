import SwiftUI

/// The floating status pill.
///
/// Deliberately tiny and text-first: it appears over whatever the user is typing into, so
/// it has to be readable at a glance and impossible to mistake for a dialog. No buttons,
/// no dismiss control — it is a status light, not a window.
struct HUDView: View {

    let phase: DictationPhase

    var body: some View {
        HStack(spacing: 10) {
            Text(phase.hudSymbol)
                .font(.system(size: 15))

            Text(phase.hudText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if case .listening(let level) = phase {
                LevelMeter(level: level)
            }

            if case .downloading(_, let progress) = phase {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        // The HUD is decoration over someone else's window; VoiceOver should hear the
        // state once, not read a pile of anonymous shapes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.hudText)
    }
}

/// Five bars that track the microphone input level.
///
/// Driven by the peak amplitude the recorder already computes, so it costs nothing extra;
/// its only job is to make "the mic is actually hearing me" obvious before the user has
/// spoken a whole sentence into a muted input.
private struct LevelMeter: View {

    let level: Float

    private static let barCount = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(isLit(index) ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Bars light up progressively. The curve is compressed at the top so normal speech
    /// uses most of the range instead of pinning at full scale.
    private func isLit(_ index: Int) -> Bool {
        let normalized = min(1, sqrt(max(0, level)) * 1.6)
        return Double(index) < Double(Self.barCount) * Double(normalized)
    }

    private func height(for index: Int) -> CGFloat {
        6 + CGFloat(min(index, Self.barCount - 1 - index)) * 3
    }
}
