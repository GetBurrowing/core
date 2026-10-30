// Social's LiveView hooks (ADR 0055; task 01a165ec stage 4). A with-Social
// release host's generated `@extensions` entry spreads this map into core's
// hooks, so core's js/hooks/index.js never imports Social. Each key is the
// `phx-hook` name Social renders: the cover picker, and the Clips tab's
// Review bay (Clip Studio 3/9, task 01a16662-8c00 stage 4), the Calendar's
// browser time zone (Social authoring 8/11), and the Queue's version strip
// (Social authoring 5/11, task 01a16c50).
import CoverPicker from "./hooks/cover_picker.js"
import ClipReview from "./hooks/clip_review.js"
import SocialCalendarZone from "./hooks/social_calendar_zone.js"
import QueueSwipe from "./hooks/queue_swipe.js"

import ClosingVideoPreview from "./hooks/closing_video_preview.js"

export default { ClosingVideoPreview, CoverPicker, ClipReview, SocialCalendarZone, QueueSwipe }
