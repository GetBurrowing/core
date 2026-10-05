import SwiftUI
import WidgetKit

/// The extension entry point. Kept apart from the views so the render
/// tests (ExtensionRenderTests) can compile the views without an `@main`.
@main
struct SuiteWidgetBundle: WidgetBundle {
    var body: some Widget {
        ApprovalsWidget()
        TasksWidget()
        OverviewWidget()
    }
}
