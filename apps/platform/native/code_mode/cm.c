/*
 * code_mode harness: QuickJS-ng compiled to wasm32-wasip1 (task 01a114a8 stage 2).
 *
 * Built by scripts/build-code-mode-wasm.sh into
 * apps/platform/priv/code_mode/quickjs_cm.wasm. Run by Platform.CodeMode.Runtime.
 *
 * Exports:  cm_alloc(n) -> ptr
 *           cm_run(script, script_len, inputs, inputs_len, config, config_len) -> ptr
 *             ptr points at [u32 little-endian length][JSON result bytes]
 * Imports:  suite.host_call(name, name_len, args, args_len, out, out_cap) -> i32
 *             the host writes at most out_cap bytes of JSON at out and returns
 *             the count (negative on host failure). It is the ONLY way out of
 *             the sandbox besides the wasi_snapshot_preview1 functions wasi-libc
 *             needs (clocks, random, fd_write to a discarding sink, proc_exit).
 *
 * No quickjs-libc: no std / os modules, no timers, no module loader, no files.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#define EXPORT(name) __attribute__((export_name(name)))

__attribute__((import_module("suite"), import_name("host_call"))) int32_t
suite_host_call(const char *name, int32_t name_len, const char *args, int32_t args_len,
                char *out, int32_t out_cap);

/* Inner results are capped at 1 MB by the host; the envelope adds a little. */
#define OUT_CAP ((1 << 20) + 65536)

static char *g_out = NULL;

/* The JS side of the bindings. Receives the native host call function and the
 * config; defines `suite`, `store`, `console` and `inputs` on globalThis and
 * returns the function that serialises the run's outcome. */
static const char PRELUDE[] =
    "(function (g, hostCall, cfg, inputs) {\n"
    "  'use strict';\n"
    "  const logs = []; let logBytes = 0, logsTruncated = false;\n"
    "  const logCap = cfg.log_cap | 0;\n"
    "  const fmt = (v) => { if (typeof v === 'string') return v;\n"
    "    try { const s = JSON.stringify(v); return s === undefined ? String(v) : s; }\n"
    "    catch (_) { return String(v); } };\n"
    "  const log = (...a) => { if (logsTruncated) return;\n"
    "    const line = a.map(fmt).join(' ');\n"
    "    if (logBytes + line.length > logCap) { logsTruncated = true; return; }\n"
    "    logBytes += line.length; logs.push(line); };\n"
    "  const fail = (r, name) => { const e = new Error(r.message || 'call failed');\n"
    "    e.name = 'SuiteError'; e.kind = r.kind; e.tool = name;\n"
    "    if (r.code !== undefined) e.code = r.code;\n"
    "    if (r.details !== undefined) e.details = r.details; return e; };\n"
    "  const raw = (name, args) => {\n"
    "    if (args === undefined) args = {};\n"
    "    if (args === null || typeof args !== 'object' || Array.isArray(args))\n"
    "      throw new TypeError(name + ': arguments must be an object');\n"
    "    const r = JSON.parse(hostCall(String(name), JSON.stringify(args)));\n"
    "    if (r.ok) return r.data; throw fail(r, name); };\n"
    "  const tree = { call: (name, args) => raw(name, args) };\n"
    "  for (const name of cfg.tools) {\n"
    "    const parts = name.split('.'); let node = tree;\n"
    "    for (let i = 0; i < parts.length - 1; i++) {\n"
    "      if (node[parts[i]] === undefined) node[parts[i]] = {};\n"
    "      node = node[parts[i]]; }\n"
    "    node[parts[parts.length - 1]] = (args) => raw(name, args); }\n"
    "  /* A name that is not bound still reaches the host, which authorizes it:\n"
    "     calling a tool outside the runtime's surface is refused as forbidden\n"
    "     (and ledgered as denied), not hidden behind a TypeError. */\n"
    "  const inert = ['then', 'toJSON', 'constructor', 'valueOf', 'toString'];\n"
    "  const wrap = (node, prefix) => {\n"
    "    for (const k of Object.keys(node))\n"
    "      if (node[k] && typeof node[k] === 'object') node[k] = wrap(node[k], prefix + k + '.');\n"
    "    Object.freeze(node);\n"
    "    return new Proxy(node, { get(t, p) {\n"
    "      if (typeof p !== 'string' || Object.prototype.hasOwnProperty.call(t, p)) return Reflect.get(t, p);\n"
    "      if (inert.includes(p)) return undefined;\n"
    "      return (args) => raw(prefix + p, args); } }); };\n"
    "  const suite = wrap(tree, '');\n"
    "  const store = {\n"
    "    get: (key) => raw('$store.get', { key }),\n"
    "    set: (key, value, opts) => raw('$store.set', { key, value, ttl: opts && opts.ttl }),\n"
    "    delete: (key) => raw('$store.delete', { key }) };\n"
    "  const def = (k, v) => Object.defineProperty(g, k, { value: v, writable: false,\n"
    "    enumerable: false, configurable: false });\n"
    "  def('suite', suite); def('store', Object.freeze(store));\n"
    "  def('console', Object.freeze({ log, info: log, warn: log, error: log, debug: log }));\n"
    "  def('inputs', inputs);\n"
    "  const kinds = ['forbidden', 'call_limit'];\n"
    "  return (ok, v) => {\n"
    "    let kind = 'script_error', msg;\n"
    "    if (ok) { let s;\n"
    "      try { s = JSON.stringify(v === undefined ? null : v); }\n"
    "      catch (e) { if (e instanceof InternalError) throw e; s = null;\n"
    "        msg = 'the result is not JSON-serialisable: ' + String(e); }\n"
    "      if (msg === undefined) return '{\"ok\":true,\"result\":' + (s === undefined ? 'null' : s) +\n"
    "        ',\"logs\":' + JSON.stringify(logs) + ',\"logs_truncated\":' + logsTruncated + '}';\n"
    "      return JSON.stringify({ ok: false, error: { kind, message: msg },\n"
    "        logs, logs_truncated: logsTruncated }); }\n"
    "    if (v instanceof Error) { msg = v.name + ': ' + v.message;\n"
    "      if (typeof v.stack === 'string') msg += '\\n' + v.stack.slice(0, 2000);\n"
    "      if (kinds.includes(v.kind)) kind = v.kind;\n"
    "      if (v.name === 'InternalError' && v.message === 'out of memory') kind = 'memory';\n"
    "    } else { msg = 'Uncaught ' + fmt(v); }\n"
    "    return JSON.stringify({ ok: false, error: { kind, message: msg.slice(0, 4000) },\n"
    "      logs, logs_truncated: logsTruncated }); };\n"
    "})";

static JSValue js_host_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    size_t name_len, args_len;
    const char *name, *args;
    int32_t n;
    (void)this_val;
    if (argc < 2)
        return JS_ThrowTypeError(ctx, "host_call needs a name and arguments");
    if (!g_out && !(g_out = malloc(OUT_CAP)))
        return JS_ThrowOutOfMemory(ctx);
    name = JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (!name)
        return JS_EXCEPTION;
    args = JS_ToCStringLen(ctx, &args_len, argv[1]);
    if (!args) {
        JS_FreeCString(ctx, name);
        return JS_EXCEPTION;
    }
    n = suite_host_call(name, (int32_t)name_len, args, (int32_t)args_len, g_out, OUT_CAP);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, args);
    if (n < 0 || n > OUT_CAP)
        return JS_ThrowInternalError(ctx, "host call failed");
    return JS_NewStringLen(ctx, g_out, (size_t)n);
}

EXPORT("cm_alloc") void *cm_alloc(int32_t n) { return malloc((size_t)(n > 0 ? n : 1)); }

static char *emit(const char *json, size_t len)
{
    char *buf = malloc(len + 4);
    if (!buf)
        return NULL;
    buf[0] = (char)(len & 0xff);
    buf[1] = (char)((len >> 8) & 0xff);
    buf[2] = (char)((len >> 16) & 0xff);
    buf[3] = (char)((len >> 24) & 0xff);
    memcpy(buf + 4, json, len);
    return buf;
}

static char *emit_str(const char *json) { return emit(json, strlen(json)); }

/* Compile `script` as global code with top-level await (its completion value
 * is the result). A script that only parses as a function body (a bare
 * `return`) is retried wrapped in an async arrow. */
static JSValue compile(JSContext *ctx, const char *script, size_t len, int *wrapped)
{
    static const char head[] = "(async () => {\n", tail[] = "\n})()";
    JSValue fn = JS_Eval(ctx, script, len, "<script>",
                         JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC | JS_EVAL_FLAG_COMPILE_ONLY);
    if (!JS_IsException(fn))
        return fn;
    JSValue first = JS_GetException(ctx);
    char *buf = malloc(len + sizeof(head) + sizeof(tail));
    if (!buf) {
        JS_Throw(ctx, first);
        return JS_EXCEPTION;
    }
    memcpy(buf, head, sizeof(head) - 1);
    memcpy(buf + sizeof(head) - 1, script, len);
    memcpy(buf + sizeof(head) - 1 + len, tail, sizeof(tail));
    fn = JS_Eval(ctx, buf, len + sizeof(head) + sizeof(tail) - 2, "<script>",
                 JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    free(buf);
    if (JS_IsException(fn)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        JS_Throw(ctx, first); /* report the unwrapped error: it names the user's line */
        return JS_EXCEPTION;
    }
    JS_FreeValue(ctx, first);
    *wrapped = 1;
    return fn;
}

EXPORT("cm_run")
char *cm_run(const char *script, int32_t script_len, const char *inputs, int32_t inputs_len,
             const char *config, int32_t config_len)
{
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = rt ? JS_NewContext(rt) : NULL;
    JSValue cfg, in, prelude, finish = JS_UNDEFINED, fn, ret, outcome, argv[4];
    int ok = 0, wrapped = 0;
    char *res;
    size_t len;
    const char *s;

    if (!ctx)
        return emit_str("{\"ok\":false,\"error\":{\"kind\":\"memory\",\"message\":\"no runtime\"}}");
    /* The wasm shadow stack is 4 MB (--stack-size); stay well inside it. */
    JS_SetMaxStackSize(rt, 1024 * 1024);

    cfg = JS_ParseJSON(ctx, config, (size_t)config_len, "<config>");
    in = JS_ParseJSON(ctx, inputs, (size_t)inputs_len, "<inputs>");
    prelude = JS_Eval(ctx, PRELUDE, sizeof(PRELUDE) - 1, "<prelude>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(cfg) || JS_IsException(in) || JS_IsException(prelude))
        return emit_str("{\"ok\":false,\"error\":{\"kind\":\"script_error\",\"message\":\"bad inputs\"}}");
    argv[0] = JS_GetGlobalObject(ctx);
    argv[1] = JS_NewCFunction(ctx, js_host_call, "hostCall", 2);
    argv[2] = cfg;
    argv[3] = in;
    finish = JS_Call(ctx, prelude, JS_UNDEFINED, 4, (JSValueConst *)argv);
    if (JS_IsException(finish))
        return emit_str("{\"ok\":false,\"error\":{\"kind\":\"script_error\",\"message\":\"prelude failed\"}}");

    fn = compile(ctx, script, (size_t)script_len, &wrapped);
    if (JS_IsException(fn)) {
        outcome = JS_GetException(ctx);
    } else {
        ret = JS_EvalFunction(ctx, fn);
        while (JS_ExecutePendingJob(rt, NULL) > 0)
            ;
        if (JS_IsException(ret)) {
            outcome = JS_GetException(ctx);
        } else if (JS_IsPromise(ret)) {
            switch (JS_PromiseState(ctx, ret)) {
            case JS_PROMISE_FULFILLED:
                outcome = JS_PromiseResult(ctx, ret);
                if (!wrapped) { /* async global code resolves to {value: completion} */
                    JSValue v = JS_GetPropertyStr(ctx, outcome, "value");
                    JS_FreeValue(ctx, outcome);
                    outcome = v;
                }
                ok = 1;
                break;
            case JS_PROMISE_REJECTED:
                outcome = JS_PromiseResult(ctx, ret);
                break;
            default:
                outcome = JS_NewError(ctx);
                JS_SetPropertyStr(ctx, outcome, "message",
                                  JS_NewString(ctx, "the script awaited a promise that never "
                                                    "settles (suite_run has no timers or I/O)"));
                break;
            }
            JS_FreeValue(ctx, ret);
        } else {
            outcome = ret;
            ok = 1;
        }
    }
    JS_RunGC(rt);
    argv[0] = ok ? JS_TRUE : JS_FALSE;
    argv[1] = outcome;
    ret = JS_Call(ctx, finish, JS_UNDEFINED, 2, (JSValueConst *)argv);
    if (JS_IsException(ret)) /* only an InternalError (memory, stack) escapes finish */
        return emit_str("{\"ok\":false,\"error\":{\"kind\":\"memory\",\"message\":"
                        "\"out of memory while serialising the result\"}}");
    s = JS_ToCStringLen(ctx, &len, ret);
    res = s ? emit(s, len) : NULL;
    /* The instance is discarded after one run; nothing else needs freeing. */
    return res ? res : emit_str("{\"ok\":false,\"error\":{\"kind\":\"memory\",\"message\":\"out of memory\"}}");
}
