/**
 * BURROW_* environment names with a SUITE_* fallback (task 01a14b9e).
 *
 * The BURROW_ name wins. The SUITE_ name is read only when the BURROW_ name is
 * unset, empty or whitespace (systemd `Environment=X=` and compose `X: ""`
 * produce ""), and then one deprecation line is printed per SUITE_ name per
 * process. Callers name both full literals; never build a name from a suffix.
 */

const warned = new Set<string>();

function present(v: string | undefined): v is string {
  return v !== undefined && v.trim() !== "";
}

export function readEnv(
  burrow: string,
  suite: string,
  env: Record<string, string | undefined> = process.env,
  warn: (line: string) => void = console.error,
): string | undefined {
  const b = env[burrow];
  if (present(b)) return b;
  const s = env[suite];
  if (!present(s)) return undefined;
  if (!warned.has(suite)) {
    warned.add(suite);
    warn(`deprecated: ${suite} is set; rename it to ${burrow}`);
  }
  return s;
}

/** Test hook: forget which SUITE_ names have already warned. */
export function resetEnvWarnings(): void {
  warned.clear();
}
