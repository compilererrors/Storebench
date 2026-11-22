import SwiftUI

/// Counts the user's own page input, such as each scroll step, so a scroll the page started itself can tell it was overtaken.
/// It is a plain reference that views never observe: scrolling changes it many times a second, and it must never make the
/// page draw again.
@MainActor final class StorebenchPageInteractions {
    private(set) var count: UInt64 = 0
    func record() { count &+= 1 }
}
