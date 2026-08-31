// Injected into the live chat page to catch whatever zeroes
// #chat-message-scroller.scrollTop when the canvases drawer opens.
// Records: every JS write to sc.scrollTop (with stack), every DOM removal /
// addition involving the scroller or its ancestors, attribute changes on the
// scroller chain, a per-frame sampler with the ancestor identity chain and
// computed displays, scroll events, and the hook callbacks.
(() => {
  const sc = document.getElementById("chat-message-scroller");
  if (!sc) return { fatal: "no #chat-message-scroller" };
  if (window.__z) return { ok: true, already: true };

  let hk = null;
  let sent = null;
  for (const v of Object.values(window.liveSocket.roots || {})) {
    for (const h of Object.values(v.viewHooks || {})) {
      if (h && h.el && h.el.id === "message-list") hk = h;
      if (h && h.el && h.el.id === "chat-scroll-sentinel-top") sent = h;
    }
  }

  const Z = { events: [], t0: performance.now() };
  window.__z = Z;
  const now = () => Math.round((performance.now() - Z.t0) * 10) / 10;
  const desc = (el) =>
    el && el.nodeType === 1
      ? el.tagName +
        (el.id ? "#" + el.id : "") +
        (typeof el.className === "string" && el.className
          ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".")
          : "")
      : String(el);
  const ev = (type, extra) => {
    const e = Object.assign({ t: now(), type }, extra);
    Z.events.push(e);
    return e;
  };
  const chain = (el) => {
    const out = [];
    let p = el;
    while (p && p !== document.documentElement) {
      out.push(p);
      p = p.parentElement;
    }
    return out;
  };

  // Tag the scroller and every ancestor so a morphdom replacement of any of
  // them shows up as "UNTAGGED" in the identity chain.
  sc.__ztag = "SC";
  chain(sc).forEach((el, i) => {
    if (!el.__ztag) el.__ztag = "a" + i;
  });
  document.documentElement.__ztag = "html";
  document.body.__ztag = "body";

  // 1. Wrap the scroller's scrollTop accessor. A JS write logs the write and
  //    a stack; a structural reset (detach / display:none / clamp) does NOT
  //    go through this accessor, so its absence is itself evidence.
  const proto = Object.getPrototypeOf(sc);
  const d =
    Object.getOwnPropertyDescriptor(proto, "scrollTop") ||
    Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop");
  Z.accessorOn = d ? "found" : "MISSING";
  if (d) {
    Object.defineProperty(sc, "scrollTop", {
      configurable: true,
      get() {
        return d.get.call(this);
      },
      set(v) {
        const before = d.get.call(this);
        if (v !== before) {
          Z.events.push({
            t: now(),
            type: "scrollTopWrite",
            from: before,
            to: v,
            stack: (new Error().stack || "")
              .split("\n")
              .slice(1, 7)
              .join(" | "),
          });
        }
        d.set.call(this, v);
      },
    });
  }

  // 2. MutationObserver over the document: removals / additions touching the
  //    scroller or its ancestors, attribute changes on the chain.
  const relation = (n) =>
    n === sc
      ? "SELF"
      : n.contains(sc)
        ? "ANCESTOR-OF-SC"
        : sc.contains(n)
          ? "DESCENDANT-OF-SC"
          : null;
  const mo = new MutationObserver((muts) => {
    for (const m of muts) {
      if (m.type === "childList") {
        for (const n of m.removedNodes) {
          if (n.nodeType !== 1) continue;
          const rel = relation(n);
          if (rel)
            ev("removed", {
              rel,
              node: desc(n) + " @" + (n.__ztag || "UNTAGGED"),
              scConnected: sc.isConnected,
              parent: desc(m.target) + " @" + (m.target.__ztag || "UNTAGGED"),
            });
        }
        for (const n of m.addedNodes) {
          if (n.nodeType !== 1) continue;
          const rel = relation(n);
          if (rel)
            ev("added", {
              rel,
              node: desc(n) + " @" + (n.__ztag || "UNTAGGED"),
              scConnected: sc.isConnected,
              parent: desc(m.target) + " @" + (m.target.__ztag || "UNTAGGED"),
            });
        }
      } else if (m.type === "attributes") {
        const t = m.target;
        if (t === sc || (t.contains && t.contains(sc))) {
          ev("attr", {
            target: desc(t) + " @" + (t.__ztag || "UNTAGGED"),
            attr: m.attributeName,
            old: m.oldValue == null ? null : String(m.oldValue).slice(0, 120),
          });
        }
      }
    }
  });
  mo.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeOldValue: true,
  });

  // 3. rAF sampler: on any scrollTop / connectivity change, freeze the
  //    identity chain + displays + activeElement.
  let lastSt = sc.scrollTop;
  let lastConn = sc.isConnected;
  const sample = () => {
    const st = sc.scrollTop;
    const conn = sc.isConnected;
    if (st !== lastSt || conn !== lastConn) {
      const f = ev("frame", {
        st,
        sh: sc.scrollHeight,
        ch: sc.clientHeight,
        conn,
      });
      f.chain = chain(sc).map(
        (el) => desc(el) + "@" + (el.__ztag || "UNTAGGED"),
      );
      f.displays = chain(sc).map((el) => getComputedStyle(el).display);
      f.activeElement = desc(document.activeElement);
      lastSt = st;
      lastConn = conn;
    }
    requestAnimationFrame(sample);
  };
  requestAnimationFrame(sample);

  // 4. scroll events (for completeness — the defect fires none).
  sc.addEventListener(
    "scroll",
    () => ev("scroll", { st: sc.scrollTop }),
    { passive: true },
  );

  // 5. Hook callbacks, same shape as gate5.mjs for comparability.
  if (hk) {
    if (hk.beforeUpdate) {
      const o = hk.beforeUpdate.bind(hk);
      hk.beforeUpdate = function () {
        o();
        ev("beforeUpdate", { preD: this._preUpdateDistance });
      };
    }
    if (hk.updated) {
      const o = hk.updated.bind(hk);
      hk.updated = function () {
        ev("updated:enter");
        o();
        ev("updated:exit");
      };
    }
    if (hk.scrollToBottom) {
      const o = hk.scrollToBottom.bind(hk);
      hk.scrollToBottom = function (dd) {
        ev("scrollToBottom:enter", { arg: dd === undefined ? null : dd });
        o(dd);
      };
    }
    if (hk._onViewportResize) {
      const o = hk._onViewportResize.bind(hk);
      hk._onViewportResize = function () {
        ev("viewportResize:enter", { st: sc.scrollTop, ch: sc.clientHeight });
        o();
        ev("viewportResize:exit", { st: sc.scrollTop, ch: sc.clientHeight });
      };
    }
    if (hk._reportDistance) {
      const o = hk._reportDistance.bind(hk);
      hk._reportDistance = function (pre) {
        o(pre);
        ev("reportDistance", {
          arg: pre === undefined ? null : pre,
          away: this._lastAway,
        });
      };
    }
  }
  if (sent) {
    const ot = sent._trigger.bind(sent);
    sent._trigger = function () {
      ev("sentinel:trigger", { preTop: this.scrollEl.scrollTop });
      ot();
      ev("sentinel:triggered", {
        capturedPreTop: this._preTop,
        capturedPreHeight: this._preHeight,
      });
    };
  }

  return { ok: true, hookFound: !!hk, sentinelFound: !!sent, accessorOn: Z.accessorOn };
})()
