// Social's LiveView hooks (ADR 0055; task 01a165ec stage 4). A with-Social
// release host's generated `@extensions` entry spreads this map into core's
// hooks, so core's js/hooks/index.js never imports Social. The key is the
// `phx-hook` name the cover picker renders.
import CoverPicker from "./hooks/cover_picker.js"

export default { CoverPicker }
