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

    // The Mac notification, once per conversation when a second terminal appears. `name` is what the person calls
    // the session: the name they gave it, else its folder.
    static func notificationTitle(name: String, count: Int) -> String {
        count == 2 ? "\(name) is open twice" : "\(name) is open in \(count) terminals"
    }
    static func notificationBody(count: Int) -> String {
        "\(count == 2 ? "Two" : "\(count)") terminals are running the same Claude conversation. Each remembers only its own part. Close the one you’re not using."
    }

    /// The status line after "Close" in the confirm, and whether it is drawn amber.
    static func closeOutcome(project: String, _ outcome: CopiesCloseOutcome) -> (text: String, failed: Bool) {
        switch outcome {
        case .closed(let count, _):
            return (count == 1 ? "Closed the other \(project) terminal" : "Closed the other \(count) \(project) terminals", false)
        case .refused(let why):
            return ("Left the other \(project) terminal open: \(why.text)", true)
        case .failed(let why):
            return ("Didn't close the other \(project) terminal: \(why)", true)
        }
    }
}
