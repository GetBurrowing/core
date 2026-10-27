/**
 * The protocol: core's commands in, observed state out.
 *
 *   in   agent.start | agent.restart  {agent_id, runtime_id, runtime_token, harness, core_url, env, files}
 *        agent.restart + ref          the same, answered by agent.restarted (tools.ts)
 *        agent.stop                   {agent_id}
 *        agent.logs                   {agent_id, lines, ref}
 *        agent.pane                   {agent_id, lines, ref}              read only (pane.ts)
 *        agent.file_read              {agent_id, key, ref}                one file, redacted (files.ts)
 *        agent.check_auth             {agent_id, ref}                     does its API key work? (auth.ts)
 *        host.env_names               {agent_id?, ref}                    env NAMES only, never values
 *        host.admin                   {op, service, tag?, ref}            restart|deploy|rollback, full_root only
 *   out  host.inventory               {profile, agents: [observation]}   on every join
 *        agent.state                  observation                         on every change
 *        agent.log                    {ref, agent_id, lines}
 *        agent.pane                   {ref, agent_id, lines, hidden}
 *        agent.file                   {ref, agent_id, content, sha256} | {ref, agent_id, error}
 *        agent.auth                   {ref, agent_id, result}             ok | rejected | unknown
 *        agent.restarted              {ref, agent_id, outcome, before, after}   tool snapshots, names only
 *        host.reply                   {ref, result}                       answer to host.env_names | host.admin
 *
 * An agent whose key a check found `rejected` reads `needs_login` (detail
 * `auth_error`) until its next start, which is the only thing that can give
 * it a new key.
 *
 * The host REPORTS its profile (`AGENT_HOST_PROFILE`, set by packaging); core
 * displays it and never branches on it.
 *
 * Commands for one agent run one at a time, in arrival order, so a stop that
 * arrives during a start waits for it rather than racing it.
 */
import {
  SUPPORTED_HARNESSES,
  agentLogs,
  knownAgents,
  observeAgent,
  parseStart,
  statusSaysLogin,
  startAgent,
  stopAgent,
  type AgentsDeps,
  type Observation,
  type StartCommand,
} from "./agents.ts";
import { checkApiKey, readAgentEnv, type AuthResult, type Fetch } from "./auth.ts";
import { isFileKey, readAgentFileRaw, redactForRead, sha256Hex } from "./files.ts";
import { homeDir, isAgentId, userName, workDir } from "./ids.ts";
import { snapshotTools, type ProbeUser, type ToolSnapshot } from "./tools.ts";
import { agentPane } from "./pane.ts";
import { deployService, restartService, rollbackService, type AdminResult, type DockerFetch } from "./docker.ts";
import type { Payload } from "./phoenix.ts";

export interface Transport {
  push(event: string, payload: Payload): Promise<string>;
}

export const WATCH_MS = 5_000;

export class Host {
  private readonly last = new Map<string, string>();
  private readonly queues = new Map<string, Promise<void>>();
  /** Agents whose API key a check found rejected since their last start. */
  private readonly authRejected = new Set<string>();

  constructor(
    private readonly deps: AgentsDeps,
    private readonly transport: Transport,
    private readonly profile: string,
    private readonly auth: AuthDeps = liveAuthDeps,
    /** True only when the install enabled `[agents] full_root`; advertised in the hello. */
    private readonly fullRoot: boolean = false,
    private readonly docker: DockerFetch | null = null,
    restart?: Partial<RestartDeps>,
  ) {
    this.restartDeps = {
      snapshot: (user) => snapshotTools({ runner: deps.runner }, user),
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      waitMs: RESTART_WAIT_MS,
      pollMs: 1_000,
      startAgent,
      ...restart,
    };
  }

  private readonly restartDeps: RestartDeps;

  /** The host's hello: its profile, and whether full root is on. */
  hello(): Payload {
    return { profile: this.profile, full_root: this.fullRoot };
  }

  /** Env names (never values) of one agent's env file. Answered as `host.reply`. */
  async handleEnvNames(payload: Payload): Promise<void> {
    const { agent_id: agentId, ref } = payload;
    if (typeof ref !== "string") return;
    const names = isAgentId(agentId) ? Object.keys(this.auth.readEnv(agentId) ?? {}).sort() : [];
    await this.transport.push("host.reply", { ref, result: { names } });
  }

  /**
   * restart | deploy | rollback of a compose service. Without full root the
   * answer is `requires_full_root` and the socket is never touched.
   */
  async handleAdmin(payload: Payload): Promise<void> {
    const { op, service, tag, ref } = payload;
    if (typeof ref !== "string") return;
    const reply = (result: AdminResult): Promise<string> => this.transport.push("host.reply", { ref, result: result as unknown as Payload });
    if (!this.fullRoot || this.docker === null) {
      await reply({ error: "requires_full_root", manifest_key: "agents.full_root" });
      return;
    }
    if (typeof service !== "string" || service.trim() === "") {
      await reply({ error: "invalid", detail: "service is required" });
      return;
    }
    try {
      const t = typeof tag === "string" && tag !== "" ? tag : undefined;
      if (op === "restart") await reply(await restartService(this.docker, service));
      else if (op === "deploy" && t !== undefined) await reply(await deployService(this.docker, service, t));
      else if (op === "rollback") await reply(await rollbackService(this.docker, service, t));
      else await reply({ error: "invalid", detail: "op must be restart, deploy (with tag) or rollback" });
    } catch (error) {
      await reply({ error: "failed", detail: error instanceof Error ? error.message : String(error) });
    }
  }

  /** What the host reports: the unit and status file, then a rejected key on top. */
  async observe(agentId: string): Promise<Observation> {
    return withAuth(await observeAgent(this.deps, agentId), this.authRejected.has(agentId));
  }

  /** Serialise work per agent. */
  private enqueue(agentId: string, work: () => Promise<void>): Promise<void> {
    const prev = this.queues.get(agentId) ?? Promise.resolve();
    const next = prev.then(work, work).catch((error: unknown) => {
      this.deps.log(`agent ${agentId}: ${error instanceof Error ? error.message : String(error)}`);
    });
    this.queues.set(agentId, next);
    return next;
  }

  async inventory(): Promise<void> {
    const agents: Observation[] = [];
    for (const id of knownAgents()) agents.push(await this.observe(id));
    for (const o of agents) this.last.set(o.agent_id, key(o));
    await this.transport.push("host.inventory", { profile: this.profile, agents: agents as unknown as Payload[] });
  }

  async report(o: Observation, force = false): Promise<void> {
    const k = key(o);
    if (!force && this.last.get(o.agent_id) === k) return;
    this.last.set(o.agent_id, k);
    await this.transport.push("agent.state", o as unknown as Payload);
  }

  /** One pass over every known agent, reporting what changed. */
  async watch(): Promise<void> {
    for (const id of knownAgents()) {
      await this.enqueue(id, async () => this.report(await this.observe(id)));
    }
  }

  handleStart(payload: Payload): Promise<void> {
    const cmd = parseStart(payload);
    if (typeof cmd === "string") {
      this.deps.log(`agent.start refused: ${cmd}`);
      return Promise.resolve();
    }
    return this.enqueue(cmd.agent_id, async () => {
      await this.start(cmd);
    });
  }

  /** The start itself, inside the agent's queue. False when the harness is not runnable here. */
  private async start(cmd: StartCommand): Promise<boolean> {
    if (!SUPPORTED_HARNESSES.has(cmd.harness)) {
      await this.report(
        { agent_id: cmd.agent_id, state: "stopped", detail: `harness ${cmd.harness} is not available on this host yet`, files_applied: null },
        true,
      );
      return false;
    }
    // A start is the only way an agent gets a new key: forget the old verdict.
    this.authRejected.delete(cmd.agent_id);
    await this.report({ agent_id: cmd.agent_id, state: "starting", detail: null, files_applied: null }, true);
    try {
      await this.restartDeps.startAgent(this.deps, cmd);
    } catch (error) {
      await this.report(
        { agent_id: cmd.agent_id, state: "crashed", detail: error instanceof Error ? error.message : String(error), files_applied: null },
        true,
      );
      throw error;
    }
    await this.report(await this.observe(cmd.agent_id));
    return true;
  }

  /**
   * `agent.restart`. Without a `ref` it is a start (the old contract). With
   * one (task 01a17b1c stage 4) the host also answers `agent.restarted`
   * `{ref, agent_id, outcome, before, after}`: a tool snapshot BEFORE the
   * files are rewritten (what the running agent loaded at its last start),
   * the restart, a wait for the agent to come back, and a snapshot after.
   * An agent at a login screen is not probed: before and after are null.
   * The same command, never a second restart path.
   */
  handleRestart(payload: Payload): Promise<void> {
    const ref = typeof payload.ref === "string" && payload.ref !== "" ? payload.ref : null;
    if (ref === null) return this.handleStart(payload);
    const cmd = parseStart(payload);
    if (typeof cmd === "string") {
      this.deps.log(`agent.restart refused: ${cmd}`);
      const agentId = isAgentId(payload.agent_id) ? payload.agent_id : "";
      return this.transport.push("agent.restarted", { ref, agent_id: agentId, outcome: "gone", before: null, after: null }).then(() => undefined);
    }
    return this.enqueue(cmd.agent_id, async () => {
      const id = cmd.agent_id;
      const user = { name: userName(id), home: homeDir(id), work: workDir(id) };
      let outcome = "gone";
      let before: ToolSnapshot | null = null;
      let after: ToolSnapshot | null = null;
      try {
        const loginBefore = (await this.observe(id)).state === "needs_login";
        before = loginBefore ? null : await this.restartDeps.snapshot(user);
        if (await this.start(cmd)) {
          outcome = await this.waitBack(id);
          after = outcome === "needs_login" || loginBefore ? null : await this.restartDeps.snapshot(user);
          if (outcome === "needs_login") before = null;
        }
      } finally {
        await this.transport.push("agent.restarted", {
          ref,
          agent_id: id,
          outcome,
          before: before as unknown as Payload,
          after: after as unknown as Payload,
        });
      }
    });
  }

  /** Until the agent reads running (ready), needs_login, crashed (gone), or the wait runs out. */
  private async waitBack(agentId: string): Promise<string> {
    const deadline = Date.now() + this.restartDeps.waitMs;
    for (;;) {
      const o = await this.observe(agentId);
      if (o.state === "running") return "ready";
      if (o.state === "needs_login") return "needs_login";
      if (o.state === "crashed") return "gone";
      if (Date.now() >= deadline) return "timeout";
      await this.restartDeps.sleep(this.restartDeps.pollMs);
    }
  }

  handleStop(payload: Payload): Promise<void> {
    const agentId = payload.agent_id;
    if (!isAgentId(agentId)) return Promise.resolve();
    return this.enqueue(agentId, async () => {
      await stopAgent(this.deps, agentId);
      await this.report(await this.observe(agentId), true);
    });
  }

  async handleLogs(payload: Payload): Promise<void> {
    const { agent_id: agentId, lines, ref } = payload;
    if (!isAgentId(agentId) || typeof ref !== "string") return;
    const out = await agentLogs(this.deps, agentId, typeof lines === "number" ? lines : 200);
    await this.transport.push("agent.log", { ref, agent_id: agentId, lines: out });
  }

  /** Recent pane text, read only, login screens withheld (pane.ts). */
  async handlePane(payload: Payload, pane: PaneDeps = { statusSaysLogin }): Promise<void> {
    const { agent_id: agentId, lines, ref } = payload;
    if (!isAgentId(agentId) || typeof ref !== "string") return;
    const out = await agentPane(this.deps.runner, agentId, typeof lines === "number" ? lines : 80, pane.statusSaysLogin(agentId));
    await this.transport.push("agent.pane", { ref, agent_id: agentId, lines: out.lines, hidden: out.hidden });
  }

  /**
   * One file of the agent's work dir, for Compare. Read as the agent, redacted
   * here (a secret value never leaves the machine) and again in core; the hash
   * is over the full bytes so core can use it as a precondition.
   */
  async handleFileRead(payload: Payload): Promise<void> {
    const { agent_id: agentId, key, ref } = payload;
    if (!isAgentId(agentId) || typeof ref !== "string") return;
    if (typeof key !== "string" || !isFileKey(key)) {
      await this.transport.push("agent.file", { ref, agent_id: agentId, error: "invalid_key" });
      return;
    }
    const r = await readAgentFileRaw(this.deps.runner, { name: userName(agentId), work: workDir(agentId) }, key);
    if (r.status === "ok") {
      await this.transport.push("agent.file", { ref, agent_id: agentId, content: redactForRead(key, r.content), sha256: sha256Hex(r.content) });
    } else {
      await this.transport.push("agent.file", { ref, agent_id: agentId, error: r.status === "not_found" ? "not_found" : "unreadable" });
    }
  }

  /**
   * core's no-reply watchdog asks whether the agent's key still works. The
   * answer goes back first; a rejected key then changes the observed state
   * (needs_login), which is reported as any change is.
   */
  handleCheckAuth(payload: Payload): Promise<void> {
    const { agent_id: agentId, ref } = payload;
    if (!isAgentId(agentId) || typeof ref !== "string") return Promise.resolve();
    return this.enqueue(agentId, async () => {
      const result = await checkApiKey(this.auth.readEnv(agentId), this.auth.fetch);
      this.deps.log(`agent ${agentId}: API key check: ${result}`);
      await this.transport.push("agent.auth", { ref, agent_id: agentId, result });
      if (result === "rejected") {
        this.authRejected.add(agentId);
        await this.report(await this.observe(agentId));
      }
    });
  }
}

export const RESTART_WAIT_MS = 90_000;

export interface RestartDeps {
  snapshot(user: ProbeUser): Promise<ToolSnapshot>;
  /** Test seam: {@link startAgent} needs root. */
  startAgent(deps: AgentsDeps, cmd: StartCommand): Promise<void>;
  sleep(ms: number): Promise<void>;
  waitMs: number;
  pollMs: number;
}

export interface AuthDeps {
  readEnv(agentId: string): Record<string, string> | null;
  fetch: Fetch;
}

export const liveAuthDeps: AuthDeps = {
  readEnv: readAgentEnv,
  fetch: (url, init) => fetch(url, init),
};

/**
 * A rejected key overrides a live observation: the unit is up and the pane
 * reads ready, but no turn can run. A stopped or crashed agent reads as itself.
 */
export function withAuth(o: Observation, rejected: boolean): Observation {
  if (!rejected || (o.state !== "running" && o.state !== "starting")) return o;
  return { ...o, state: "needs_login", detail: "auth_error", login: { step: "auth_error" } };
}

export type { AuthResult };

export interface PaneDeps {
  statusSaysLogin(agentId: string): boolean;
}

function key(o: Observation): string {
  return JSON.stringify([o.state, o.detail, o.login ?? null, o.files_applied ?? null, o.files_drifted ?? null]);
}
