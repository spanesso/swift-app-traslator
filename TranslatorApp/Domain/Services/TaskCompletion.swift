//
//  TaskCompletion.swift
//  TranslatorApp
//
//  Bounded wait for a task to finish on its own (research 2026-09-15, finding P1).
//
//  Shutting the pipeline down used to mean cancelling its consumers first and asking questions
//  later — which is how the last phrase of every meeting was thrown away. The order is now
//  "finish, then wait for the consumers to drain", and this is the wait: long enough for the last
//  words to arrive, never long enough to hang a stop.
//

import Foundation

enum TaskCompletion {

    /// Waits for `task` to complete. If it has not completed after `milliseconds`, it is
    /// cancelled.
    ///
    /// - Returns: true when the task finished by itself.
    @discardableResult
    nonisolated static func wait(for task: Task<Void, Never>?, upToMs milliseconds: Int) async -> Bool {
        guard let task else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(milliseconds, 0)) * 1_000_000)
                return false
            }
            let finishedFirst = await group.next() ?? false
            // Cancel the task itself BEFORE leaving the group: the group waits for every child,
            // and the one awaiting `task.value` only returns once the task has ended.
            if !finishedFirst { task.cancel() }
            group.cancelAll()
            return finishedFirst
        }
    }
}
