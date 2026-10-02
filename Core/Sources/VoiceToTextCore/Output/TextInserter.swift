/// Inserts final text at the cursor of the frontmost app (v1: pasteboard + Cmd+V).
public protocol TextInserter: Sendable {
    @MainActor func insert(_ text: String) async throws
}
