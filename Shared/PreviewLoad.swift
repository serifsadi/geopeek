//
//  PreviewLoad.swift
//  Shared — compiled into the app, the preview, and the thumbnail appex.
//
//  Which in-flight open may update the window. A newer open invalidates
//  every earlier ticket. Cancelled opens do not apply either.
//

/// Tickets for file loads started in one window.
struct FileLoadGate: Sendable {
    private(set) var current: UInt64 = 0

    /// Starts a load. Tickets from earlier calls no longer apply.
    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    /// Drops the current ticket. The in-flight load can no longer apply,
    /// including when the view that started it has gone away.
    mutating func invalidate() {
        current &+= 1
    }

    /// True only for the ticket `begin()` returned most recently, and only
    /// when that load has not been cancelled. A false result must not change
    /// the window or Recents.
    func canApply(ticket: UInt64, isCancelled: Bool) -> Bool {
        !isCancelled && ticket != 0 && ticket == current
    }
}
