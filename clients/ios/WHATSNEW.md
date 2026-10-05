# Burrow iOS: TestFlight "What to Test"

The top `## v<version>` section is sent as the build's "What to Test" by
`scripts/set_testflight_notes.py`. It must match project.yml's
MARKETING_VERSION, and it is capped at 4000 characters.

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
- The app icon is a placeholder until Marlowe's final icon lands.
- Meetings run in the web view only. Meeting audio stops when the app is backgrounded or the phone is locked; there is no CallKit or ringing.
- Not built: native meetings, native game streaming, Apple Watch, Siri and Shortcuts.
- Share uploads are capped at 8 MB per file; larger files fail.
