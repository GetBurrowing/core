# Burrow Android: Play release notes

The top `## v<version>` section is sent as the release notes of the Play
internal-track release by `scripts/play_upload.py` (Play caps them at 500
characters). It must match `versionName` in `android/app/build.gradle`.

## v1.0
New in this build:
- One app, many installs: notifications from every install you're signed in to, with the install's name on each one and unread counts per install. An install that is down shows Could not update.
- Notifications show the sender's picture.
- No built-in installs: new users start at Add your install. Saved installs and sign-ins are kept.
- Sharing explains when an install has moved to another address.
- The keyboard no longer hides Continue when adding an install.

## v1.0, versionCodes up to 6
First internal build of Burrow for Android: the Burrow web app in a native shell.

Please try:
- Sign in to your install, then allow notifications when asked.
- Mentions: reply from the notification, or tap Open to land in the space.
- Share a photo, link, PDF or a large video (up to 1 GB by default) to a Burrow space; it uploads in the background.
- Add the My approvals and My tasks widgets to your home screen.

Known gaps: no native meetings yet.
