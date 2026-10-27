/**
 * The container-runtime socket, used only when full root is on (task
 * 01a17b10 stage 3): restart a compose service, or move its image tag.
 *
 * Which socket is `AGENT_HOST_RUNTIME_SOCKET` (default /var/run/docker.sock).
 * The service is found by its compose label, so no list of names is kept here.
 * Nothing in this file is reachable unless the host advertised `full_root`.
 */

export interface DockerResponse {
  status: number;
  json(): Promise<unknown>;
  text(): Promise<string>;
}
export type DockerFetch = (path: string, init: { method: string; body?: string }) => Promise<DockerResponse>;

export const DEFAULT_SOCKET = "/var/run/docker.sock";

export function socketPath(env: Record<string, string | undefined> = process.env): string {
  const v = env.AGENT_HOST_RUNTIME_SOCKET?.trim();
  return v ? v : DEFAULT_SOCKET;
}

export function liveDockerFetch(socket: string): DockerFetch {
  return (path, init) =>
    fetch(`http://docker${path}`, {
      method: init.method,
      body: init.body,
      headers: init.body ? { "content-type": "application/json" } : undefined,
      // Bun's unix-socket fetch option.
      unix: socket,
    } as RequestInit) as unknown as Promise<DockerResponse>;
}

export type AdminResult = Record<string, unknown>;

interface Inspect {
  Id: string;
  Name: string;
  Config: { Image: string } & Record<string, unknown>;
  HostConfig: Record<string, unknown>;
  NetworkSettings: { Networks: Record<string, Record<string, unknown>> };
}

/** repo[:tag] -> [repo, tag]; a registry port colon is not a tag. */
export function splitImage(image: string): [string, string] {
  const at = image.indexOf("@");
  const bare = at >= 0 ? image.slice(0, at) : image;
  const colon = bare.lastIndexOf(":");
  const slash = bare.lastIndexOf("/");
  if (colon > slash) return [bare.slice(0, colon), bare.slice(colon + 1)];
  return [bare, "latest"];
}

/** The previous image per service, in memory: a rollback with no tag moves back to it. */
export const previousImage = new Map<string, string>();

async function ok(res: DockerResponse, what: string): Promise<void> {
  if (res.status >= 200 && res.status < 300) return;
  throw new Error(`${what} failed with HTTP ${res.status}`);
}

async function findContainer(d: DockerFetch, service: string): Promise<string> {
  const filters = encodeURIComponent(JSON.stringify({ label: [`com.docker.compose.service=${service}`] }));
  const res = await d(`/containers/json?filters=${filters}`, { method: "GET" });
  await ok(res, "list containers");
  const rows = (await res.json()) as Array<{ Id: string }>;
  const first = rows[0];
  if (!first) throw new Error(`no container for service ${service}`);
  return first.Id;
}

export async function restartService(d: DockerFetch, service: string): Promise<AdminResult> {
  const id = await findContainer(d, service);
  await ok(await d(`/containers/${id}/restart`, { method: "POST" }), "restart");
  return { service, restarted: true };
}

/** Pull `repo:tag` and recreate the service's container on it. */
export async function deployService(d: DockerFetch, service: string, tag: string): Promise<AdminResult> {
  const id = await findContainer(d, service);
  const res = await d(`/containers/${id}/json`, { method: "GET" });
  await ok(res, "inspect");
  const info = (await res.json()) as Inspect;
  const [repo, oldTag] = splitImage(info.Config.Image);
  const image = `${repo}:${tag}`;
  const pull = await d(`/images/create?fromImage=${encodeURIComponent(repo)}&tag=${encodeURIComponent(tag)}`, { method: "POST" });
  await ok(pull, "pull");
  await pull.text();

  const name = info.Name.replace(/^\//, "");
  const stamp = Date.now();
  await ok(await d(`/containers/${id}/stop`, { method: "POST" }), "stop");
  await ok(await d(`/containers/${id}/rename?name=${encodeURIComponent(`${name}-prev-${stamp}`)}`, { method: "POST" }), "rename");
  const endpoints: Record<string, unknown> = {};
  for (const net of Object.keys(info.NetworkSettings.Networks)) endpoints[net] = {};
  const create = await d(`/containers/create?name=${encodeURIComponent(name)}`, {
    method: "POST",
    body: JSON.stringify({
      ...info.Config,
      Image: image,
      HostConfig: info.HostConfig,
      NetworkingConfig: { EndpointsConfig: endpoints },
    }),
  });
  await ok(create, "create");
  const created = (await create.json()) as { Id: string };
  await ok(await d(`/containers/${created.Id}/start`, { method: "POST" }), "start");
  previousImage.set(service, `${repo}:${oldTag}`);
  return { service, image, previous: `${repo}:${oldTag}`, retained_container: `${name}-prev-${stamp}` };
}

/** Move back to `tag`, or to the image before the last deploy this process made. */
export async function rollbackService(d: DockerFetch, service: string, tag?: string): Promise<AdminResult> {
  const target = tag ?? previousImage.get(service)?.split(":").pop();
  if (!target) throw new Error("no previous image is known for this service; pass a tag");
  return deployService(d, service, target);
}
