// Play's LiveView hooks (ADR 0055, task 01a0ee08 stage 3). A with-Play release
// host's generated `@extensions` entry spreads this map into core's hooks, so
// core's js/hooks/index.js never imports Play. The key is the `phx-hook` name
// the game_stream canvas kind renders.
import GameStream from "./hooks/game_stream.js"

export default { GameStream }
