import SwiftUI
import WidgetKit

/// The extension entry point. Kept apart from the views so the render
/// tests (ExtensionRenderTests) can compile the views without an `@main`.
/// The controls need iOS 18; the widgets target stays on 17.
@main
struct BurrowWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Gallery order (task 01a21e75 stage 4): the feed widgets first,
        // Waiting on you leading (stage 5 inserts Voice second), then the
        // existing widgets in their v1 order.
        WaitingWidget()
        BlockedWidget()
        RecentWidget()
        ShippedWidget()
        ApprovalsWidget()
        TasksWidget()
        OverviewWidget()
        if #available(iOS 18, *) {
            WhatsWaitingControl()
            StartMeetingControl()
        }
    }
}
