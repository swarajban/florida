import FloridaKit
import SwiftUI

/// One block on the grid: an event in its calendar color with the account rim, a task block in
/// its category color (dashed until pinned), or a ghost. Sized and placed by the parent; shows
/// the time range when tall enough. `isLifted` draws the copy that follows the finger (opaque;
/// the parent adds its shadow and scale, so idle blocks carry neither).
struct DayGridBlockView: View {
    let block: DayGridLayout.Block
    /// The block's own time, or the slot it is being dragged over.
    let timeText: String
    let showsTime: Bool
    let isPast: Bool
    var isLifted = false

    private var alpha: Double {
        block.isDone ? 0.5 : (isPast ? 0.6 : 1)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let textColor = FloridaStyle.ink.opacity(alpha)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 2) {
                Text(block.title)
                    .font(.caption.weight(.medium))
                    .strikethrough(block.isDone)
                    .lineLimit(showsTime ? 2 : 1)
                Spacer(minLength: 0)
                if block.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .padding(.top, 2)
                }
            }
            if showsTime {
                Text(timeText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, block.rim == nil ? 5 : 7)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(block.tint.opacity(fillOpacity), in: shape)
        .background {
            // Behind the tint (each `background` goes further back): the lifted copy is opaque
            // over the blocks it passes.
            if isLifted {
                shape.fill(FloridaStyle.paper)
            }
        }
        .overlay {
            shape.strokeBorder(
                block.tint.opacity(strokeOpacity),
                style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
        }
        .overlay(alignment: .leading) {
            if let rim = block.rim {
                RoundedRectangle(cornerRadius: 1)
                    .fill(rim.opacity(alpha))
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(timeText)
        .accessibilityAddTraits(.isButton)
    }

    private var fillOpacity: Double {
        (block.isEvent ? 0.12 : 0.08) * alpha + (isLifted ? 0.1 : 0)
    }

    private var strokeOpacity: Double {
        (block.isEvent ? 0.5 : 0.6) * alpha
    }

    /// Task blocks the scheduler may still move are dashed; pinned ones and events are solid.
    private var dashed: Bool {
        !block.isEvent && !block.isPinned
    }

    private var accessibilityLabel: String {
        var parts = [block.title]
        if block.isPinned { parts.append("pinned") }
        if block.isDone { parts.append("done") }
        return parts.joined(separator: ", ")
    }
}
