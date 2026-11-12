// Arrow keys move among real game links. Native Enter activation remains intact.
export function installConsoleShelves(doc = document) {
  doc.addEventListener('keydown', event => {
    const tile = event.target.closest?.('[data-game-tile]')
    if (!tile || event.altKey || event.ctrlKey || event.metaKey || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return
    const shelf = tile.closest('.cg-shelf')
    const tiles = [...shelf.querySelectorAll('[data-game-tile]')]
    const next = tiles[tiles.indexOf(tile) + (event.key === 'ArrowRight' ? 1 : -1)]
    if (!next) return
    event.preventDefault()
    next.focus({preventScroll: true})
    next.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'})
  })
}
