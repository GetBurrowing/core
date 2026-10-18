// window.burrow (also window.suite, the same object): the canvas room bridge, injected into every prototype HTML
// file (task 01a1316b-84fa stage 2). ES2017, no imports. No network: it only
// postMessages the parent page, whose CanvasRoomBridge hook relays it.
(function (w) {
  "use strict"
  if (w.suite && w.suite.__bridge) return
  var up = w.parent
  var linked = up && up !== w
  var keys = {}
  var cols = {}
  var seq = null
  var reqN = 0
  var pending = {}
  var calls = {}
  var held = []
  var subs = { change: [], presence: [], broadcast: [] }
  var markReady
  var ready = new Promise(function (r) { markReady = r })
  var GAP = 34 // ms between broadcasts per channel: 30/s
  var sent = {}
  var queued = {}

  function post(m) {
    m.suite = 1
    if (linked) up.postMessage(m, "*")
  }
  function emit(kind, ev) {
    subs[kind].forEach(function (fn) {
      try { fn(ev) } catch (e) { setTimeout(function () { throw e }) }
    })
  }
  function copy(v) { return v === undefined ? v : JSON.parse(JSON.stringify(v)) }
  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }

  function op(o) {
    if (!suite.connected) return Promise.reject(new Error("not_connected"))
    var req = "r" + (++reqN)
    return new Promise(function (res, rej) {
      var m = { type: "op", req: req, op: o, suite: 1 }
      // The hook drops >64 KB unanswered
      if (new TextEncoder().encode(JSON.stringify(m)).length > 65536) return rej(new Error("too_large"))
      pending[req] = { res: res, rej: rej }
      post(m)
    })
  }

  // suite.call(name, args): run the canvas handler `name` in the room, as
  // the signed-in viewer (task 01a1316b-aab0 stage 2). Resolves with
  // {ok: true, result} once the mirror has the handler's ops; rejects with
  // an Error carrying .kind and .code (e.g. forbidden / binding_not_registered).
  function call(name, args) {
    if (!suite.connected) return Promise.reject(coded({ kind: "not_connected" }))
    var req = "c" + (++reqN)
    return new Promise(function (res, rej) {
      var m = { type: "call", req: req, name: name, args: args === undefined ? {} : args, suite: 1 }
      if (new TextEncoder().encode(JSON.stringify(m.args)).length > 16384) return rej(coded({ kind: "too_large" }))
      calls[req] = { res: res, rej: rej }
      post(m)
    })
  }

  function coded(m) {
    var e = new Error(m.code || m.kind || "error")
    e.name = "SuiteError"
    e.kind = m.kind || "error"
    e.code = m.code || e.kind
    if (m.message) e.detail = m.message
    return e
  }

  function onCallResult(m) {
    var p = calls[m.req]
    if (!p) return
    delete calls[m.req]
    if (!m.ok) { p.rej(coded(m)); return }
    held.push({ seq: m.seq, result: { ok: true, result: m.result }, res: p.res })
    release()
  }

  // An ack can beat its diff: hold it until the mirror reaches its seq.
  function release() {
    held = held.filter(function (h) {
      if (seq !== null && h.seq > seq) return true
      h.res(h.result)
      return false
    })
  }

  function onSnapshot(m) {
    var oldK = keys
    var oldC = cols
    suite.connected = m.connected !== false
    if (!suite.connected) { markReady(suite); return }
    keys = (m.state && m.state.keys) || {}
    cols = (m.state && m.state.collections) || {}
    seq = m.seq
    suite.me = m.me || suite.me
    if (m.presence) {
      suite.presence = m.presence
      emit("presence", copy(m.presence))
    }
    Object.keys(Object.assign({}, oldK, keys)).forEach(function (k) {
      if (!same(oldK[k], keys[k]))
        emit("change", { kind: "key", key: k, value: copy(keys[k]), seq: seq, actor: null })
    })
    Object.keys(Object.assign({}, oldC, cols)).forEach(function (n) {
      if (!same(oldC[n], cols[n]))
        emit("change", { kind: "collection", name: n, items: copy(cols[n] || []), seq: seq, actor: null })
    })
    release()
    markReady(suite)
  }

  function onDiff(m) {
    if (seq === null || m.seq <= seq) return
    if (m.seq !== seq + 1) { seq = null; post({ type: "hello" }); return }
    var d = m.diff || {}
    seq = m.seq
    if (d.kind === "key") {
      if (d.value === null || d.value === undefined) delete keys[d.key]
      else keys[d.key] = d.value
      emit("change", { kind: "key", key: d.key, value: copy(d.value), seq: seq, actor: m.actor })
    } else if (d.kind === "collection") {
      var items = (cols[d.name] || []).slice()
      var i = items.findIndex(function (x) { return x.id === d.id })
      if (d.op === "add" && i < 0) items.push(d.item)
      else if (d.op === "update" && i >= 0) items[i] = d.item
      else if (d.op === "remove" && i >= 0) items.splice(i, 1)
      cols[d.name] = items
      emit("change", { kind: "collection", name: d.name, items: copy(items), seq: seq, actor: m.actor })
    }
    release()
  }

  function onAck(m) {
    var p = pending[m.req]
    if (!p) return
    delete pending[m.req]
    if (!m.ok) { p.rej(new Error(m.error || "error")); return }
    held.push({ seq: m.seq, result: m.result, res: p.res })
    release()
  }

  function flush(ch) {
    var q = queued[ch]
    delete queued[ch]
    sent[ch] = Date.now()
    post({ type: "ephemeral", channel: ch, payload: q.payload })
  }

  var suite = {
    __bridge: 1,
    ready: ready,
    connected: false,
    call: call,
    me: null,
    presence: [],
    state: {
      get: function (k) { return copy(keys[k]) },
      set: function (k, v) { return op({ type: "state.set", key: k, value: v === undefined ? null : v }) },
      increment: function (k, by) { return op({ type: "state.increment", key: k, by: by === undefined ? 1 : by }) }
    },
    collection: function (n) {
      return {
        list: function () { return copy(cols[n] || []) },
        add: function (item) { return op({ type: "collection.add", name: n, item: item }) },
        update: function (id, patch) { return op({ type: "collection.update", name: n, id: id, patch: patch }) },
        remove: function (id) { return op({ type: "collection.remove", name: n, id: id }) }
      }
    },
    on: function (kind, fn) {
      if (!subs[kind]) throw new Error("unknown event " + kind)
      subs[kind].push(fn)
      return function () { subs[kind] = subs[kind].filter(function (f) { return f !== fn }) }
    },
    // Throttled to 30/s per channel; the latest payload wins.
    broadcast: function (ch, payload) {
      if (!suite.connected) return
      var waiting = queued[ch]
      queued[ch] = { payload: payload }
      if (waiting) return
      var wait = GAP - (Date.now() - (sent[ch] || 0))
      if (wait <= 0) flush(ch)
      else setTimeout(function () { flush(ch) }, wait)
    }
  }

  w.addEventListener("message", function (ev) {
    if (!linked || ev.source !== up) return
    var m = ev.data
    if (!m || m.suite !== 1) return
    if (m.type === "snapshot") onSnapshot(m)
    else if (m.type === "diff") onDiff(m)
    else if (m.type === "ack") onAck(m)
    else if (m.type === "call_result") onCallResult(m)
    else if (m.type === "presence") {
      suite.presence = m.presence || []
      emit("presence", copy(suite.presence))
    } else if (m.type === "ephemeral")
      emit("broadcast", { channel: m.channel, payload: m.payload, actor: m.actor })
  })

  w.suite = suite
  // window.burrow is the same object (task 01a14b9e-50a4 stage 1), so
  // window.burrow === window.suite and either name drives one bridge.
  w.burrow = suite
  if (!linked) markReady(suite)
  else {
    post({ type: "hello" })
    // A host page with no room (a read-only surface) never answers.
    setTimeout(function () { markReady(suite) }, 3000)
  }
})(window)
