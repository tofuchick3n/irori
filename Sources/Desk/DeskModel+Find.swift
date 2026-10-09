import Foundation

extension DeskModel {
    var findMatches: [FindMatch] {
        guard isFinding, let thread = selectedThread else { return [] }
        return TranscriptFind.matches(in: thread.messages, query: findQuery)
    }

    func currentFindIndex(among count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(findIndex ?? count - 1, count - 1)
    }

    func beginFind() {
        isFinding = true
        findFocusRequest += 1
    }

    func endFind() {
        isFinding = false
        findIndex = nil
    }

    /// Escape closes the find bar first, then the files drawer. Returns whether it closed either.
    func dismissForEscape() -> Bool {
        if isFinding {
            endFind()
        } else if showsFiles {
            showsFiles = false
        } else {
            return false
        }
        return true
    }

    /// Moves to the next match (`step` 1) or the previous one (-1), wrapping at either end.
    func moveFind(_ step: Int) {
        if !isFinding {
            beginFind()
        }
        let count = findMatches.count
        guard let current = currentFindIndex(among: count) else { return }
        findIndex = ((current + step) % count + count) % count
    }
}
