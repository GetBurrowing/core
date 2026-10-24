// Social's LiveView hooks (ADR 0055; task 01a165ec stage 4). A with-Social
// release host's generated `@extensions` entry spreads this map into core's
// hooks, so core's js/hooks/index.js never imports Social. Each key is the
// `phx-hook` name Social renders: the cover picker, and the Clips tab's
// Review bay (Clip Studio 3/9, task 01a16662-8c00 stage 4).
import CoverPicker from "./hooks/cover_picker.js"
import ClipReview from "./hooks/clip_review.js"

export default { CoverPicker, ClipReview }
