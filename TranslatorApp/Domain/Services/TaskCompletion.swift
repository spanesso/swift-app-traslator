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
//  NEVER LONGER THAN THE BOUND (field log 2026-09-15). The first version raced the task inside a
//  task group, cancelled it on timeout and then — because a group waits for all its children —
//  waited for it anyway. A task that ignores cancellation, like SpeechAnalyzer's finalisation,
//  turned the bounded wait into an unbounded one. Now two watchers race to resume one
//  continuation, and whichever loses simply finishes later on its own.
//

import Foundation
import os

enum TaskCompletion {

    /// Waits for `task` to complete. If it has not completed after `milliseconds`, it is
    /// cancelled and the wait returns anyway.
    ///
    /// - Returns: true when the task finished by itself.
    @discardableResult
    nonisolated static func wait(for task: Task<Void, Never>?, upToMs milliseconds: Int) async -> Bool {
        guard let task else { return true }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                await task.value
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(milliseconds, 0)) * 1_000_000)
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                task.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
