import SwiftUI
import WidgetKit

/// The extension entry point. Kept apart from the views so the render
/// tests (ExtensionRenderTests) can compile the views without an `@main`.
/// The controls need iOS 18; the widgets target stays on 17.
@main
struct SuiteWidgetBundle: WidgetBundle {
    var body: some Widget {
        ApprovalsWidget()
        TasksWidget()
        OverviewWidget()
        if #available(iOS 18, *) {
            WhatsWaitingControl()
            StartMeetingControl()
        }
    }
}
