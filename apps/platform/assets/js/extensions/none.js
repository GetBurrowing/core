// The `@extensions` hook registry of the without-modules build (ADR 0055,
// task 01a0ee08 stage 3): no module, no hooks. core's `platform` esbuild
// profile aliases `@extensions` here; a with-modules release host aliases it
// to the entry it generates instead. Nothing in apps/platform is generated.
export default {}
