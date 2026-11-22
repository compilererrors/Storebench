/// The input that goes Back and Forward in history besides the keyboard shortcuts, as in Safari and Finder: the mouse's side
/// buttons and a swipe between pages.
public enum HistoryGesture {
    /// The mouse's fourth button goes Back and its fifth Forward.
    public static func command(mouseButton: Int) -> ShortcutCommand? { mouseButton == 3 ? .back : mouseButton == 4 ? .forward : nil }
    /// Swiping right shows the earlier page and swiping left the later one.
    public static func command(swipeX: Double) -> ShortcutCommand? { swipeX > 0 ? .back : swipeX < 0 ? .forward : nil }
    /// The hover help of a Back or Forward button, with its shortcut when it has one.
    public static func help(_ command: ShortcutCommand, binding: ShortcutBinding?) -> String {
        binding.map { "\(command.title) (\($0.display))" } ?? command.title
    }
}
