import Foundation

/// A window model that may be running a job the user should not lose by closing the window.
@MainActor
protocol BackgroundWork: AnyObject {
    var isBusy: Bool { get }
    var busyTitle: String { get }
    /// Cancels the job and returns once its cleanup (partial files, staging folders) is done.
    func cancelAndWait() async
}
