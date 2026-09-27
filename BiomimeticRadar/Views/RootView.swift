import SwiftUI

/// One screen. That is the whole app.
///
/// It had six tabs — Live, Stream, Analyze, Signals, Geometry, Experiment, Results — until
/// 2026-08-23, when the analysis moved to the Mac. What is left is a recorder: watch the field,
/// start the stream, see it reach the server. The old views are in git history at `94529ba` and
/// their logic is still in `Processing/` for the Python ports; nothing was thrown away, it was
/// moved to where it can be iterated on without a device build.
struct RootView: View {
    var body: some View {
        NavigationStack { StreamView() }
            .tint(LabTheme.cyan)
    }
}
