//
//  LiveActivityCoordinator.swift
//  IntelliDocScanSignPDF
//

import ActivityKit
import Foundation
import Observation

/// Owns the document-processing Live Activity: starts it when a multi-page
/// scan, batch redaction or signing/upload begins, streams progress into the
/// Dynamic Island + Lock Screen, and dismisses it 3 seconds after completion.
@MainActor
@Observable
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    private var activity: Activity<ScanActivityAttributes>?
    private var dismissalTask: Task<Void, Never>?

    private init() {}

    private var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Starts a fresh activity for `documentTitle` if none is running.
    func begin(
        title: String,
        pageCount: Int,
        folderName: String,
        status: UploadStatus = .scanning
    ) {
        guard activitiesEnabled else { return }
        endActive(immediate: true)

        let attributes = ScanActivityAttributes(
            documentTitle: title,
            pageCount: pageCount,
            folderName: folderName
        )
        let state = ScanActivityAttributes.ContentState(
            uploadProgress: status == .scanning ? 0.05 : 0.2,
            status: status
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            // Live Activities unavailable (older device, disabled setting).
            activity = nil
        }
    }

    /// Streams a progress update into the activity.
    func update(progress: Double, status: UploadStatus) async {
        guard let activity else { return }
        let clamped = min(1, max(0, progress))
        await activity.update(.init(
            state: .init(uploadProgress: clamped, status: status),
            staleDate: nil
        ))
    }

    /// Nudges progress while a stage runs (OCR, hashing, rendering).
    func advance(stage: UploadStatus, to progress: Double) async {
        await update(progress: progress, status: stage)
    }

    /// Marks the pipeline complete and dismisses the activity 3s later.
    func complete() async {
        guard let activity else { return }
        await activity.update(.init(
            state: .init(uploadProgress: 1, status: .completed),
            staleDate: nil
        ))

        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.endActive(immediate: true)
        }
    }

    /// Marks the pipeline failed; the system dismisses on the default policy.
    func fail() async {
        guard let activity else { return }
        await activity.update(.init(
            state: .init(uploadProgress: 0, status: .failed),
            staleDate: nil
        ))
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.endActive(immediate: true)
        }
    }

    /// Ends any running activity immediately (e.g. user cancelled).
    func endActive(immediate: Bool = false) {
        dismissalTask?.cancel()
        dismissalTask = nil
        guard let activity else { return }
        let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .default
        Task {
            await activity.end(activity.content, dismissalPolicy: policy)
        }
        self.activity = nil
    }
}
