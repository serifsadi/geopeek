// The window applies a file load only when its ticket is still the latest
// and the load was not cancelled. A slower earlier read must not replace
// the file on screen or add itself to Recents.
//
//   swiftc -swift-version 5 -o /tmp/verify-load-gate \
//     Shared/PreviewLoad.swift test-fixtures/verify-load-gate.swift
//   /tmp/verify-load-gate

import Foundation

var failures = 0

func fail(_ message: String) {
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

@main
enum VerifyLoadGate {
    static func main() {
        run()
        if failures > 0 {
            fputs("\(failures) failure(s)\n", stderr)
            exit(1)
        }
        print("ok: only the latest uncancelled file load may apply")
    }
}

func run() {
    let idle = FileLoadGate()
    check(!idle.canApply(ticket: 0, isCancelled: false), "no load has started")
    check(!idle.canApply(ticket: 1, isCancelled: false), "a ticket that was never issued")

    var gate = FileLoadGate()
    let first = gate.begin()
    check(gate.canApply(ticket: first, isCancelled: false), "the only load may apply")
    check(!gate.canApply(ticket: first, isCancelled: true), "a cancelled load must not apply")

    // The reported race: file A is still reading when the window opens B.
    // A's late result must not paint the window or land in Recents.
    let slow = first
    let latest = gate.begin()
    var noted: [String] = []
    var cleared: [String] = []
    record("A", ticket: slow, readable: true, gate: gate, noted: &noted, cleared: &cleared)
    record("A-missing", ticket: slow, readable: false, gate: gate, noted: &noted, cleared: &cleared)
    record("B", ticket: latest, readable: true, gate: gate, noted: &noted, cleared: &cleared)
    check(noted == ["B"], "superseded load recorded \(noted), want [B]")
    check(cleared.isEmpty, "superseded unreadable file cleared the window: \(cleared)")
    check(!gate.canApply(ticket: slow, isCancelled: false), "A is no longer current")
    check(gate.canApply(ticket: latest, isCancelled: false), "B is the load that may apply")
    check(!gate.canApply(ticket: latest, isCancelled: true), "cancelling B drops it too")

    // The load that is still current keeps today's failure behavior.
    var missingGate = FileLoadGate()
    let missing = missingGate.begin()
    var missingNoted: [String] = []
    var missingCleared: [String] = []
    record("missing", ticket: missing, readable: false, gate: missingGate,
           noted: &missingNoted, cleared: &missingCleared)
    check(missingNoted.isEmpty, "an unreadable file was recorded: \(missingNoted)")
    check(missingCleared == ["missing"], "the current unreadable file must leave the window")

    // Back removes the map while the read is still running. That load must
    // not record a Recent or clear a file opened afterwards.
    var left = FileLoadGate()
    let abandoned = left.begin()
    left.invalidate()
    var leftNoted: [String] = []
    var leftCleared: [String] = []
    record("abandoned", ticket: abandoned, readable: true, gate: left,
           noted: &leftNoted, cleared: &leftCleared)
    record("abandoned-missing", ticket: abandoned, readable: false, gate: left,
           noted: &leftNoted, cleared: &leftCleared)
    check(leftNoted.isEmpty, "a load left behind was recorded: \(leftNoted)")
    check(leftCleared.isEmpty, "a load left behind cleared the window: \(leftCleared)")

    // Paste takes a ticket while it chooses a name. A later open takes the
    // next ticket, so the paste must not replace that file.
    var pasteThenOpen = FileLoadGate()
    let paste = pasteThenOpen.begin()
    let opened = pasteThenOpen.begin()
    check(!pasteThenOpen.canApply(ticket: paste, isCancelled: false),
          "a paste must not replace a newer load")
    check(pasteThenOpen.canApply(ticket: opened, isCancelled: false),
          "the load after a paste may apply")
    check(!pasteThenOpen.canApply(ticket: paste, isCancelled: true),
          "a cancelled paste must not apply")

    var rapid = FileLoadGate()
    var tickets: [UInt64] = []
    for _ in 0..<50 {
        tickets.append(rapid.begin())
    }
    for (index, ticket) in tickets.enumerated() {
        let current = index == tickets.count - 1
        check(rapid.canApply(ticket: ticket, isCancelled: false) == current,
              "ticket \(ticket) current=\(current)")
        check(!rapid.canApply(ticket: ticket, isCancelled: true),
              "cancelled ticket \(ticket) applied")
    }
    check(tickets == (1...50).map(UInt64.init), "tickets are not sequential: \(tickets)")
}

/// Mirrors the window: only an applicable load records a Recent or clears
/// the window when the file cannot be read. Paste files are filtered later,
/// inside Recents, and are not part of this decision.
func record(
    _ name: String,
    ticket: UInt64,
    readable: Bool,
    gate: FileLoadGate,
    noted: inout [String],
    cleared: inout [String]
) {
    guard gate.canApply(ticket: ticket, isCancelled: false) else { return }
    if readable {
        noted.append(name)
    } else {
        cleared.append(name)
    }
}
