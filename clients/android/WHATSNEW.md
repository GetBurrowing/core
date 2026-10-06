# Burrow Android: Play release notes

The top `## v<version>` section is sent as the release notes of the Play
internal-track release by `scripts/play_upload.py` (Play caps them at 500
characters). It must match `versionName` in `android/app/build.gradle`.

## v1.0
First internal build of Burrow for Android: the Burrow web app in a native shell.

Please try:
- Sign in to your install, then allow notifications when asked.
- Mentions: reply from the notification, or tap Open to land in the space.
- Share a photo, link or PDF from another app to a Burrow space.
- Add the My approvals and My tasks widgets to your home screen.

Known gaps: no native meetings yet; files over 8 MB cannot be shared.
