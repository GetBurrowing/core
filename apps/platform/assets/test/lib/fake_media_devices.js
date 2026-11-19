// A MediaDeviceInfo the way a real browser hands it out (task 01a1f4c5
// stage 5). `deviceId`, `kind`, `label` and `groupId` are getters on the
// PROTOTYPE, not own properties, so `{ ...info }` and `Object.assign({}, info)`
// copy nothing at all. Plain-object fixtures hid exactly that: a spread in
// `listDevices` left every row in a real browser with no deviceId and no label.
//
// Every device test feeds `enumerateDevices` through `asDeviceInfos` so the
// getter shape is the default, not an opt-in.

const FIELDS = new WeakMap()

export class FakeMediaDeviceInfo {
  constructor({ deviceId = "", kind = "", label = "", groupId = "" } = {}) {
    FIELDS.set(this, { deviceId, kind, label, groupId })
  }

  get deviceId() {
    return FIELDS.get(this).deviceId
  }

  get kind() {
    return FIELDS.get(this).kind
  }

  get label() {
    return FIELDS.get(this).label
  }

  get groupId() {
    return FIELDS.get(this).groupId
  }

  toJSON() {
    return { ...FIELDS.get(this) }
  }
}

export function asDeviceInfo(device) {
  return device instanceof FakeMediaDeviceInfo ? device : new FakeMediaDeviceInfo(device)
}

// A fresh list of getter-only infos, as each enumerateDevices() call returns.
export function asDeviceInfos(list) {
  return (list || []).map(asDeviceInfo)
}
