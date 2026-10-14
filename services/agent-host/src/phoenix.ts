/**
 * A minimal Phoenix channels client for ONE channel: the v2 JSON wire format
 * (`[join_ref, ref, topic, event, payload]`), heartbeats, replies, and
 * reconnect with backoff.
 *
 * The agent host authenticates with a header (`x-agent-host-token`), not a
 * query parameter, so the token never appears in a URL that a proxy logs.
 * Bun's WebSocket takes `headers` in its constructor options.
 */

export type Payload = Record<string, unknown>;

export interface SocketLike {
  readyState: number;
  send(data: string): void;
  close(): void;
  onopen: ((ev: unknown) => void) | null;
  onclose: ((ev: unknown) => void) | null;
  onerror: ((ev: unknown) => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
}

export type SocketFactory = (url: string, headers: Record<string, string>) => SocketLike;

export const HEARTBEAT_MS = 30_000;
export const RECONNECT_BASE_MS = 1_000;
export const RECONNECT_MAX_MS = 30_000;
const OPEN = 1;

/** `<core>/agent-host/websocket?vsn=2.0.0`, with ws(s) for http(s). */
export function agentHostUrl(coreUrl: string): string {
  const u = new URL(coreUrl);
  u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
  u.pathname = `${u.pathname.replace(/\/+$/, "")}/agent-host/websocket`;
  u.search = "";
  u.searchParams.set("vsn", "2.0.0");
  return u.toString();
}

/** Backoff for the nth consecutive failure: 1s, 2s, 4s … capped at 30s. */
export function backoffMs(attempt: number): number {
  return Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * 2 ** Math.max(0, attempt));
}

export interface ChannelOptions {
  url: string;
  headers: Record<string, string>;
  topic: string;
  joinPayload(): Payload;
  socket: SocketFactory;
  log(line: string): void;
  onJoined(): void;
  setTimer?(fn: () => void, ms: number): unknown;
  clearTimer?(handle: unknown): void;
}

type Pending = (status: string, response: unknown) => void;

export class PhoenixChannel {
  private ws: SocketLike | null = null;
  private ref = 0;
  private joinRef: string | null = null;
  private joined = false;
  private attempt = 0;
  private heartbeat: unknown = null;
  private stopped = false;
  private readonly handlers = new Map<string, (payload: Payload) => void>();
  private readonly pending = new Map<string, Pending>();
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (h: unknown) => void;

  constructor(private readonly opts: ChannelOptions) {
    this.setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  }

  on(event: string, fn: (payload: Payload) => void): void {
    this.handlers.set(event, fn);
  }

  isJoined(): boolean {
    return this.joined;
  }

  connect(): void {
    if (this.stopped) return;
    const ws = this.opts.socket(this.opts.url, this.opts.headers);
    this.ws = ws;
    ws.onopen = () => {
      this.joinRef = this.nextRef();
      this.send([this.joinRef, this.joinRef, this.opts.topic, "phx_join", this.opts.joinPayload()]);
      this.pending.set(this.joinRef, (status, response) => {
        if (status === "ok") {
          this.joined = true;
          this.attempt = 0;
          this.opts.log("joined");
          this.opts.onJoined();
        } else {
          this.opts.log(`join refused: ${JSON.stringify(response)}`);
          ws.close();
        }
      });
      this.scheduleHeartbeat();
    };
    ws.onmessage = (ev) => this.receive(ev.data);
    ws.onerror = () => {};
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.joined = false;
      this.ws = null;
      if (this.heartbeat !== null) this.clearTimer(this.heartbeat);
      for (const fail of this.pending.values()) fail("error", { reason: "closed" });
      this.pending.clear();
      if (this.stopped) return;
      const wait = backoffMs(this.attempt++);
      this.opts.log(`disconnected; reconnecting in ${wait} ms`);
      this.setTimer(() => this.connect(), wait);
    };
  }

  /** Push an event on the channel; resolves with the reply status. */
  push(event: string, payload: Payload): Promise<string> {
    if (!this.joined || this.ws === null) return Promise.resolve("not_joined");
    const ref = this.nextRef();
    return new Promise((resolve) => {
      this.pending.set(ref, (status) => resolve(status));
      this.send([this.joinRef, ref, this.opts.topic, event, payload]);
    });
  }

  stop(): void {
    this.stopped = true;
    this.ws?.close();
  }

  private nextRef(): string {
    this.ref += 1;
    return String(this.ref);
  }

  private send(frame: unknown[]): void {
    if (this.ws !== null && this.ws.readyState === OPEN) this.ws.send(JSON.stringify(frame));
  }

  private scheduleHeartbeat(): void {
    this.heartbeat = this.setTimer(() => {
      if (this.ws === null) return;
      this.send([null, this.nextRef(), "phoenix", "heartbeat", {}]);
      this.scheduleHeartbeat();
    }, HEARTBEAT_MS);
  }

  private receive(data: unknown): void {
    let frame: unknown;
    try {
      frame = JSON.parse(String(data));
    } catch {
      return;
    }
    if (!Array.isArray(frame) || frame.length !== 5) return;
    const [, ref, topic, event, payload] = frame as [unknown, unknown, unknown, unknown, unknown];
    if (event === "phx_reply" && typeof ref === "string") {
      const done = this.pending.get(ref);
      if (done !== undefined) {
        this.pending.delete(ref);
        const p = (payload ?? {}) as { status?: unknown; response?: unknown };
        done(typeof p.status === "string" ? p.status : "error", p.response);
      }
      return;
    }
    if (topic !== this.opts.topic || typeof event !== "string") return;
    if (event === "phx_close" || event === "phx_error") {
      this.ws?.close();
      return;
    }
    const handler = this.handlers.get(event);
    if (handler !== undefined && typeof payload === "object" && payload !== null) handler(payload as Payload);
  }
}

/** Bun's WebSocket, with the auth header. */
export const bunSocket: SocketFactory = (url, headers) =>
  new WebSocket(url, { headers } as unknown as string[]) as unknown as SocketLike;
