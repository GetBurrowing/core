import AppIntents

/// The App Shortcuts (canvas 01a10db8, "App Shortcuts phrases"), verbatim.
/// Every phrase carries the app name, as iOS requires. App-only: the
/// widget extension compiles the intents but not this provider.
struct BurrowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsWaitingIntent(),
            phrases: ["What's waiting for me in \(.applicationName)"],
            shortTitle: "What's Waiting",
            systemImageName: "tray.full")
        AppShortcut(
            intent: ShowApprovalsIntent(),
            phrases: ["Show my approvals in \(.applicationName)"],
            shortTitle: "My Approvals",
            systemImageName: "checkmark.seal")
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Ask an agent in \(.applicationName)",
                "Ask \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "Ask an Agent",
            systemImageName: "cpu")
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Send a message in \(.applicationName)",
                "Message \(\.$space) in \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane")
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: ["Start a meeting in \(.applicationName)"],
            shortTitle: "Start Meeting",
            systemImageName: "video.badge.plus")
        AppShortcut(
            intent: ShowTasksIntent(),
            phrases: ["Show my tasks in \(.applicationName)"],
            shortTitle: "My Tasks",
            systemImageName: "checklist")
        AppShortcut(
            intent: ApproveIntent(),
            phrases: ["Approve a plan in \(.applicationName)"],
            shortTitle: "Approve Plan",
            systemImageName: "checkmark.seal")
    }
}
