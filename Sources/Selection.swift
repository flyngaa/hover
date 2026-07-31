import Foundation

/// Which transcripts are "marked" (checked) in the sidebar, plus the anchor used
/// for shift-click / shift-arrow range selection.
///
/// Pure value logic — no engine, no views. All the fiddly range/anchor rules live
/// here so they can be unit-tested directly. The engine holds one of these and
/// forwards the sidebar's calls to it.
struct Selection: Equatable {

    /// The set of marked transcript ids.
    var markedIDs: Set<String> = []

    /// The id a range selection extends from (usually the last one toggled).
    var anchorID: String?

    var isEmpty: Bool { markedIDs.isEmpty }

    func isMarked(_ id: String) -> Bool { markedIDs.contains(id) }

    /// The single marked id, or nil when zero or more than one are marked.
    var primaryID: String? {
        guard markedIDs.count == 1 else { return nil }
        return markedIDs.first
    }

    /// Unmark everything and drop the anchor.
    mutating func clear() {
        markedIDs.removeAll()
        anchorID = nil
    }

    /// Mark all of `ids`, keeping an existing anchor if there is one.
    mutating func markAll(_ ids: [String]) {
        markedIDs = Set(ids)
        if anchorID == nil { anchorID = ids.first }
    }

    /// Flip one id on/off; it becomes the new anchor either way.
    mutating func toggle(_ id: String) {
        if markedIDs.contains(id) {
            markedIDs.remove(id)
        } else {
            markedIDs.insert(id)
        }
        anchorID = id
    }

    /// Extend the selection from the anchor to `id` along `orderedIDs`
    /// (shift-click / shift-arrow). Falls back to a single mark if there's no
    /// usable anchor or the target isn't visible.
    mutating func markRange(to id: String, in orderedIDs: [String]) {
        guard let targetIndex = orderedIDs.firstIndex(of: id) else {
            markedIDs = [id]
            anchorID = id
            return
        }

        let anchorIndex: Int
        if let anchorID, let index = orderedIDs.firstIndex(of: anchorID) {
            anchorIndex = index
        } else if let markedID = markedIDs.first, let index = orderedIDs.firstIndex(of: markedID) {
            anchorIndex = index
        } else {
            markedIDs = [id]
            anchorID = id
            return
        }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        markedIDs.formUnion(orderedIDs[range])
        anchorID = id
    }

    /// Swap a marked id for a new one (e.g. after a rename/move changes its id).
    mutating func replace(_ oldID: String, with newID: String) {
        guard markedIDs.contains(oldID) else { return }
        markedIDs.remove(oldID)
        markedIDs.insert(newID)
        if anchorID == oldID { anchorID = newID }
    }

    /// Drop an id that no longer exists (e.g. after a delete), fixing the anchor.
    mutating func unmarkDeleted(_ id: String) {
        markedIDs.remove(id)
        if anchorID == id { anchorID = markedIDs.first }
    }
}
