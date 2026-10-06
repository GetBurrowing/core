# Burrow iOS: TestFlight "What to Test"

The top `## v<version>` section is sent as the build's "What to Test" by
`scripts/set_testflight_notes.py`. It must match project.yml's
MARKETING_VERSION, and it is capped at 4000 characters.

## v1.1
Burrow now works with Siri, Shortcuts, Spotlight and Control Center, the My approvals widget can approve, and Burrow runs natively on iPad. The app is recoloured to the Burrow palette: orange for actions, cyan only for a live count.

Please try:
1. Siri. Say "What's waiting for me in Burrow". Siri reads your approvals and tasks and shows up to three. "Approve a plan in Burrow" always asks you to confirm and needs the phone unlocked; saying no sends nothing.
2. Ask an agent. "Ask an agent in Burrow", pick an agent and ask a question. If the agent answers within about 20 seconds Siri reads the reply; otherwise Burrow tells you it will notify you.
3. Shortcuts. In the Shortcuts app, find Burrow's actions: What's Waiting, My Approvals, Ask an Agent, Send Message, Start Meeting, My Tasks, Approve Plan. Send Message asks before it sends.
4. Spotlight. Search for a space, task, meeting or agent by name; tapping a result opens it in Burrow. Sign out of an install and check its results disappear.
5. Approvals widget. Add My approvals at medium or large size (extra-large on iPad). Tap Approve: the row asks "Approve {title}?". Tap Confirm within 8 seconds to approve, or wait and it goes back. Reject opens the task so you can write a note. Long-press the widget to pick which install it shows.
6. Control Center (iOS 18). Add Burrow's What's waiting and Start meeting controls.
7. iPad. The install picker and share sheet are centred sheets; rotate, use Split View and Slide Over, and check nothing is cut off.

Known gaps in this build:
- Meetings run in the web view only. Meeting audio stops when the app is backgrounded or the phone is locked; there is no CallKit or ringing.
- Not built: native meetings, native game streaming, Apple Watch.
- Share uploads are capped at 8 MB per file; larger files fail.

## v1.0
First internal build of Burrow, the Suite iPhone app: the Suite web app in a native shell, with native push, a share sheet and widgets.

Please try:
1. Pick an install. The first screen lists suite.example.com (default), suite.example.com and suite.milv.life. Pick yours and check the choice is remembered after quitting the app.
2. Log in. Sign-in opens in a system sheet (passkey or password), then returns you to Burrow already signed in.
3. Mention push. Have someone @-mention you, then lock the phone. Long-press the notification: Reply should post your answer without opening the app, and Open should land on that message.
4. Review and plan push. A review request or a plan awaiting you should arrive as a notification whose Open lands on it.
5. Share to Burrow. From Photos, Files, Safari or Notes, share a photo, a PDF, a link or some text to Burrow, pick a space, and send. Check it appears in that space.
6. Widgets. Add My approvals and My tasks to the home screen, and the small widgets to the lock screen. Counts should match Suite and tapping should open the right page.

Known gaps in this build:
- Meetings run in the web view only. Meeting audio stops when the app is backgrounded or the phone is locked; there is no CallKit or ringing.
- Not built: native meetings, native game streaming, Apple Watch.
- Share uploads are capped at 8 MB per file; larger files fail.
