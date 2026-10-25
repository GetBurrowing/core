// Play's LiveView hooks (ADR 0055, task 01a0ee08 stage 3). A with-Play release
// host's generated `@extensions` entry spreads this map into core's hooks, so
// core's js/hooks/index.js never imports Play. The key is the `phx-hook` name
// the game_stream canvas kind (and the Game view, task 01a1557a-efdd) renders.
import GameStream from "./hooks/game_stream.js"
import GameViewDialog from "./hooks/game_view_dialog.js"
import GameViewShare from "./hooks/game_view_share.js"

export default { GameStream, GameViewDialog, GameViewShare }
