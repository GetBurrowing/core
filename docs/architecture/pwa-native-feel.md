# PWA Native Feel: iOS Input Zoom, Text Overflow, and Scroll Behavior

## Problem Statement

When using Suite as a PWA on iOS:

1. **Input zoom**: Tapping the chat compose input triggers iOS Safari's auto-zoom because the font-size is below 16px. This changes the viewport scale, and the user must double-tap to reset. This is the single biggest friction point.

2. **Horizontal scroll on long messages**: Messages with long unbroken text (URLs, code, base64 strings) overflow the chat pane horizontally, creating an unwanted horizontal scroll. Messages should wrap, not overflow.

3. **Viewport drift**: After the zoom-on-focus, the viewport doesn't always return to the correct position when the keyboard dismisses. The view feels "unmoored."

---

## Fix 1: Prevent iOS Input Zoom

iOS Safari auto-zooms inputs with font-size < 16px. Our compose input uses `text-sm` (14px).

### Solution: Set all input/textarea/select to 16px on mobile

```css
/* In app.css or Tailwind layer */
@media screen and (max-width: 768px) {
  input, textarea, select {
    font-size: 16px !important;
  }
}
```

Or more targeted — just the compose input and any interactive inputs:

**Files to change:**
- `chat_live.ex` line 1738: change `text-sm` to `text-base` (16px) on mobile
  - Use responsive: `class="input input-bordered min-w-0 flex-1 rounded-xl text-base md:text-sm"`
  - This keeps 14px on desktop (denser) and 16px on mobile (no zoom)
- Same for thread compose textarea (line 1904): `text-base md:text-sm`
- Same for search input (line 1221): `text-base md:text-sm`
- Settings modal inputs: `text-base md:text-sm`

### Also: viewport meta tag

Current: `<meta name="viewport" content="width=device-width, initial-scale=1" />`

Add `maximum-scale=1` to prevent any zoom at all in PWA mode:
```html
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover" />
```

Note: `maximum-scale=1` is controversial for accessibility — it prevents pinch-to-zoom globally. In a PWA that's meant to feel native, this is acceptable (native apps don't allow pinch zoom on text). But we should still keep font sizes readable.

`viewport-fit=cover` handles the iOS notch/safe area properly.

### Keyboard dismiss behavior

Add a blur handler that resets viewport position after iOS keyboard dismisses:

```javascript
// In a JS hook or global
document.addEventListener('focusout', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
    // Scroll to top of viewport to reset any iOS zoom drift
    window.scrollTo(0, 0);
  }
});
```

This is already partially implemented (noted in memory from 2026-03-18) but may need to be verified in the current build.

---

## Fix 2: Prevent Horizontal Scroll on Long Messages

Messages with URLs, code blocks, or long unbroken strings cause horizontal overflow.

### Solution: CSS word-breaking on message content

Add to the message paragraph elements:

```css
.message-content {
  overflow-wrap: break-word;
  word-break: break-word;
  min-width: 0;
}
```

**Files to change:**
- `chat_live.ex` line 1577: add `break-words` (Tailwind class) to the message `<p>` tag
  ```heex
  class="text-sm leading-6 text-base-content break-words"
  ```
- Same for thread messages (line 1839)
- Same for search result content
- The message list container should have `overflow-x-hidden` to prevent any horizontal scroll:
  ```heex
  class="flex-1 overflow-y-auto overflow-x-hidden px-5 py-4 flex flex-col justify-end space-y-1"
  ```

### Code blocks and pre-formatted text

If messages contain code blocks (backtick fences), those should use:
```css
pre, code {
  overflow-x: auto;
  max-width: 100%;
  white-space: pre-wrap;
  word-break: break-all;
}
```

This lets code blocks scroll horizontally within their own container without affecting the parent message list.

---

## Fix 3: Safe Area and Bottom Padding

iOS PWAs need to account for the home indicator bar and safe areas.

### Solution: CSS env() safe area insets

```css
/* Bottom compose bar needs padding for home indicator */
.compose-bar {
  padding-bottom: env(safe-area-inset-bottom, 0);
}

/* Overall layout should respect safe areas */
body {
  padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
}
```

The `viewport-fit=cover` meta tag (from Fix 1) is required for `env()` safe area values to work.

---

## Fix 4: Scroll-to-Bottom After Send

After sending a message, the chat should scroll to the bottom reliably. The ScrollToBottom hook exists but may not fire correctly after keyboard dismiss on iOS.

Ensure the hook:
1. Scrolls after the DOM update (message added to stream)
2. Scrolls after keyboard dismiss (with a small delay to let iOS animate)
3. Doesn't fight with iOS's own scroll restoration

---

## Implementation Priority

1. **Input font-size → 16px on mobile** (highest impact, easiest fix)
2. **viewport meta tag update** (one line, prevents all zoom)
3. **break-words on messages** (prevents horizontal scroll)
4. **overflow-x-hidden on message list** (belt-and-suspenders)
5. **Safe area padding** (polish)
6. **Scroll-to-bottom reliability** (may already work, verify)

---

## Testing Checklist

- [ ] PWA on iPhone: tap compose input, no zoom
- [ ] PWA on iPhone: type long message, no horizontal scroll
- [ ] PWA on iPhone: receive long message (URL, code), no horizontal scroll  
- [ ] PWA on iPhone: dismiss keyboard, viewport returns to normal
- [ ] PWA on iPhone: send message, chat scrolls to bottom
- [ ] PWA on iPhone: safe area respected (no content behind home indicator)
- [ ] Desktop: compose input remains compact (14px / text-sm)
- [ ] Desktop: no visual regression from responsive font-size change
