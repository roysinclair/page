import Foundation

// One Claude conversation open in more than one terminal (Designs/session-copies.md). Only the words and the
// shape of what a card needs are here; which copy leads, and closing the others, are the Mac's logic.

/// What a session's card knows about its other copies.
struct SessionCopies: Equatable {
    /// How many live terminals have the conversation open (2 or more).
    var count: Int
    /// "Close the other" is offered: every other copy is idle or at a shell, and Page Studio can close its terminal.
    var canCloseOther: Bool
}

enum SessionCopiesCopy {
    /// The amber line on a Now panel card.
    static func line(count: Int) -> String { "Open in \(count) terminals · close one" }
    static let closeButton = "Close the other"
    static let closeHelp = "Close the other terminal that has this conversation open. Asks first."

    /// The confirm: a question, then what it will and won't do.
    static func confirmQuestion(project: String) -> String { "Close the other \(project) terminal?" }
    static let confirmDetail = "Claude there is idle. Its part of the conversation stays in the history."
    static let confirmCancel = "Cancel"
    static let confirmClose = "Close"
}
