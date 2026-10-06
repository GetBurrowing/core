# Burrow iOS: TestFlight "What to Test"

The top `## v<version>` section is sent as the build's "What to Test" by
`scripts/set_testflight_notes.py`. It must match project.yml's
MARKETING_VERSION, and it is capped at 4000 characters.

## v1.2
Meetings are now native. Joining a meeting from Burrow runs it as a real phone call: audio keeps going when you leave the app or lock the phone, the Lock Screen and AirPods control it, and a call shows in the phone app's Recents. If someone invites you while their meeting is live, or a meeting you were invited to starts, your phone rings like a call.

Please try:
1. Join natively. Open a meeting in Burrow and join. You get Burrow's own call screen (dark): agents first, then people; a cyan ring shows who is speaking. Mute, Audio and Leave are at the bottom.
2. Background and lock. During a call, go to the Home Screen, then lock the phone. You should keep hearing everyone, and the Lock Screen shows the call controls. Tap the Burrow button there to come back.
3. Open full meeting. On the call screen, tap Open full meeting: the web meeting page opens and the call keeps its audio (you should not hear anyone twice).
4. Ringing. Ask someone to invite you to a meeting that is live right now (meeting page, Invite). Your phone rings with "{Name} in {Meeting}". Answer joins you; Decline tells them you declined; leaving it 30 seconds counts as missed. A scheduled meeting you are invited to rings everyone invited when it starts, except whoever started it. A meeting nobody was invited to rings nobody (members still get the usual notification).
5. A second invite during a call. While you are in a call, have someone invite you to another live meeting: instead of ringing, a banner says "Invites you to join" with Not now and Switch. Switch leaves this call and joins the other.
6. Siri and Shortcuts. "Start a meeting in Burrow" now starts the call natively.

Known gaps in this build:
- PushToTalk (walkie-talkie style talk) is not built; it is a separate follow-up.
- No custom ringtone or call-screen icon yet; the system defaults are used.
- Not built: native game streaming, Apple Watch.
- Share uploads are capped at 8 MB per file; larger files fail.

## v1.1
Burrow now works with Siri, Shortcuts, Spotlight and Control Center, the My approvals widget can approve, and Burrow runs natively on iPad. The app is recoloured to the Burrow palette: orange for actions, cyan only for a live count.

Fixed: the app crashed when joining a meeting. Burrow now asks for the microphone the first time you join one.

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
