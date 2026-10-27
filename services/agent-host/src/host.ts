/**
 * The protocol: core's commands in, observed state out.
 *
 *   in   agent.start | agent.restart  {agent_id, runtime_id, runtime_token, harness, core_url, env, files}
 *        agent.stop                   {agent_id}
 *        agent.logs                   {agent_id, lines, ref}
 *        agent.pane                   {agent_id, lines, ref}              read only (pane.ts)
 *        agent.check_auth             {agent_id, ref}                     does its API key work? (auth.ts)
 *        host.env_names               {agent_id?, ref}                    env NAMES only, never values
 *        host.admin                   {op, service, tag?, ref}            restart|deploy|rollback, full_root only
 *   out  host.inventory               {profile, agents: [observation]}   on every join
 *        agent.state                  observation                         on every change
 *        agent.log                    {ref, agent_id, lines}
 *        agent.pane                   {ref, agent_id, lines, hidden}
 *        agent.auth                   {ref, agent_id, result}             ok | rejected | unknown
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
} from "./agents.ts";
import { checkApiKey, readAgentEnv, type AuthResult, type Fetch } from "./auth.ts";
import { isAgentId } from "./ids.ts";
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
  ) {}

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
    const agentId = typeof payload.agent_id === "string" ? payload.agent_id : "";
    if (typeof cmd === "string") {
      this.deps.log(`agent.start refused: ${cmd}`);
      return Promise.resolve();
    }
    return this.enqueue(cmd.agent_id, async () => {
      if (!SUPPORTED_HARNESSES.has(cmd.harness)) {
        await this.report(
          { agent_id: agentId, state: "stopped", detail: `harness ${cmd.harness} is not available on this host yet`, files_applied: null },
          true,
        );
        return;
      }
      // A start is the only way an agent gets a new key: forget the old verdict.
      this.authRejected.delete(cmd.agent_id);
      await this.report({ agent_id: cmd.agent_id, state: "starting", detail: null, files_applied: null }, true);
      try {
        await startAgent(this.deps, cmd);
      } catch (error) {
        await this.report(
          { agent_id: cmd.agent_id, state: "crashed", detail: error instanceof Error ? error.message : String(error), files_applied: null },
          true,
        );
        throw error;
      }
      await this.report(await this.observe(cmd.agent_id));
    });
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
  return JSON.stringify([o.state, o.detail, o.login ?? null, o.files_applied ?? null]);
}
