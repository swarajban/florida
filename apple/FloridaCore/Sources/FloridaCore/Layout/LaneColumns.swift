import Foundation

/// Keeps parallel work in lane order on the hour grid. `DayLayout` gives each block the lowest
/// free column, by start then length, so two lanes that start at different times can come out
/// swapped. Pure arithmetic on its frames, no I/O.
public enum LaneColumns {
    /// `frames` as `DayLayout.layout` returned them for one day, with the columns of every
    /// cluster that holds two or more lanes reassigned: of two blocks that share any time, the
    /// lower lane is always drawn to the left. `lanes` maps a frame's id to its
    /// `Placement.lane` / `PlanBlock.lane`; ids without an entry have no lane.
    ///
    /// In such a cluster the blocks without a lane (an event added since the scheduler ran, a
    /// ghost, a suggestion) keep `DayLayout`'s rule among themselves in the leftmost columns, and
    /// the lanes follow to their right. Every other cluster is returned untouched.
    public static func ordered<ID: Hashable & Sendable>(_ frames: [LayoutFrame<ID>], lanes: [ID: Int]) -> [LayoutFrame<ID>] {
        guard lanes.count > 1 else { return frames }
        var result = frames
        var first = 0
        while first < result.count {
            // A cluster, as `DayLayout` forms it: a run of frames that each start before the
            // latest end so far.
            var end = first + 1
            var clusterEnd = result[first].endMinute
            while end < result.count, result[end].startMinute < clusterEnd {
                clusterEnd = max(clusterEnd, result[end].endMinute)
                end += 1
            }
            reorder(&result, cluster: first..<end, lanes: lanes)
            first = end
        }
        return result
    }

    private static func reorder<ID: Hashable & Sendable>(
        _ frames: inout [LayoutFrame<ID>], cluster: Range<Int>, lanes: [ID: Int]
    ) {
        // Laned frames by lane, then in drawing order (by start, longer first).
        var laned: [(index: Int, lane: Int)] = []
        for index in cluster {
            if let lane = lanes[frames[index].id] {
                laned.append((index, lane))
            }
        }
        guard Set(laned.map(\.lane)).count > 1 else { return }
        laned.sort { ($0.lane, $0.index) < ($1.lane, $1.index) }

        // End minute of the last frame without a lane in each of the leftmost columns.
        var columnEnds: [Int] = []
        for index in cluster where lanes[frames[index].id] == nil {
            let column = columnEnds.firstIndex { $0 <= frames[index].startMinute } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(0)
            }
            columnEnds[column] = frames[index].endMinute
            frames[index].column = column
        }

        // Each laned frame takes the first column right of every lower lane it shares time with.
        // Two frames of one lane only overlap when a short one is drawn at the minimum height;
        // the later one then steps one column further right.
        var columnCount = columnEnds.count
        var placed: [(index: Int, lane: Int)] = []
        for item in laned {
            let frame = frames[item.index]
            let beside = placed.filter {
                frames[$0.index].startMinute < frame.endMinute && frames[$0.index].endMinute > frame.startMinute
            }
            var column = columnEnds.count
            for other in beside where other.lane < item.lane {
                column = max(column, frames[other.index].column + 1)
            }
            while beside.contains(where: { frames[$0.index].column == column }) {
                column += 1
            }
            frames[item.index].column = column
            placed.append(item)
            columnCount = max(columnCount, column + 1)
        }

        for index in cluster {
            frames[index].columnCount = columnCount
        }
    }
}
