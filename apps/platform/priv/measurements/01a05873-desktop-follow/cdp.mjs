// Minimal CDP driver over Node 22's built-in WebSocket.
// CDP_HOST: the browser may run in a container on a REMOTE box (e.g. podman
// on moon) while this driver runs on hive — override instead of re-forking.
const HOST = process.env.CDP_HOST || "127.0.0.1:9222";

export async function http(path) {
  const r = await fetch(`http://${HOST}${path}`);
  const t = await r.text();
  try {
    return JSON.parse(t);
  } catch {
    return t;
  }
}

export class Conn {
  constructor(url) {
    this.url = url;
    this.id = 0;
    this.pending = new Map();
    this.handlers = [];
  }
  async open() {
    this.ws = new WebSocket(this.url);
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = rej;
    });
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { res, rej } = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      } else {
        this.handlers.forEach((h) => h(m));
      }
    };
    return this;
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(
        JSON.stringify(
          sessionId
            ? { id, method, params, sessionId }
            : { id, method, params },
        ),
      );
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          rej(new Error("timeout " + method));
        }
      }, 60000);
    });
  }
  close() {
    this.ws.close();
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
