/**
 * Running a child process, and the rule that no secret is ever in its argv.
 *
 * A command line is readable by every user on the machine through `ps` and
 * `/proc/<pid>/cmdline`. On this host that means by every OTHER AGENT. So a
 * runtime token, an API key, or any value core sent as a secret goes to a
 * child through stdin or a 0600 file, never as an argument.
 *
 * Mirrors suite-cli's `assertNoSecretsInArgv` (src/secrets.ts): every argv
 * this daemon spawns passes through {@link Runner.run}, which refuses one that
 * contains a value registered in the {@link SecretRegistry}.
 */

export class SecretInArgv extends Error {
  readonly index: number;
  constructor(index: number) {
    super(
      `argument ${index} contains a secret value; a command line is world-readable via ps. ` +
        `Pass it on stdin or in a 0600 file instead.`,
    );
    this.name = "SecretInArgv";
    this.index = index;
  }
}

/** Every secret value this process currently holds, for the argv check. Never logged. */
export class SecretRegistry {
  private readonly held = new Set<string>();
  add(value: string): void {
    if (value !== "") this.held.add(value);
  }
  values(): string[] {
    return [...this.held];
  }
}

/** Throw if any element of `argv` contains a held secret. */
export function assertNoSecretsInArgv(argv: string[], secrets: SecretRegistry): void {
  const values = secrets.values();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] ?? "";
    if (values.some((s) => arg.includes(s))) throw new SecretInArgv(i);
  }
}

export interface RunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface RunOptions {
  /** Bytes for the child's stdin: the channel for a secret. */
  stdin?: string;
  env?: Record<string, string>;
  cwd?: string;
}

export interface Runner {
  run(argv: string[], options?: RunOptions): Promise<RunResult>;
}

/** The real runner: argv only, never a shell string, argv checked first. */
export function liveRunner(secrets: SecretRegistry): Runner {
  return {
    async run(argv, options = {}) {
      if (argv.length === 0) throw new Error("run requires a command");
      assertNoSecretsInArgv(argv, secrets);
      const proc = Bun.spawn(argv, {
        cwd: options.cwd,
        env: options.env ?? (process.env as Record<string, string>),
        stdin: options.stdin === undefined ? "ignore" : new Blob([options.stdin]),
        stdout: "pipe",
        stderr: "pipe",
      });
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      return { exitCode, stdout, stderr };
    },
  };
}

/** A runner that records every argv and delegates, for the argv leak tests. */
export function recordingRunner(inner: Runner, seen: string[][]): Runner {
  return {
    run(argv, options) {
      seen.push([...argv]);
      return inner.run(argv, options);
    },
  };
}
