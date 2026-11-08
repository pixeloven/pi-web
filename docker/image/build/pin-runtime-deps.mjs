#!/usr/bin/env node
// Pin the packed PI WEB manifest to the release's own package-lock.json.
//
// `npm pack` omits package-lock.json, so installing the tarball re-resolves
// every range at image build time. Upstream declares its Pi peers as "*" and
// npm auto-installs peers, so an unpinned build can pick up a newer, untested
// Pi core. Run from the source checkout after `npm ci`, before `npm pack`:
//
//   node pin-runtime-deps.mjs > pinned.json
//
// Every dependency, optional dependency, and peer dependency is rewritten to
// the exact version the lockfile resolved. The pinned sets are printed as JSON
// on stdout. A missing lockfile entry fails the build: a partial pin is worse
// than no image.
import { readFileSync, writeFileSync } from "node:fs";

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const lock = JSON.parse(readFileSync("package-lock.json", "utf8"));

function lockedSpec(name, spec) {
  const entry = lock.packages?.[`node_modules/${name}`];
  if (!entry?.version) {
    throw new Error(`no package-lock.json entry for "${name}"`);
  }
  // Keep npm aliases such as "npm:typebox@1.3.37" pointing at the real package.
  if (typeof spec === "string" && spec.startsWith("npm:")) {
    return `npm:${entry.name ?? name}@${entry.version}`;
  }
  return entry.version;
}

for (const field of ["dependencies", "optionalDependencies", "peerDependencies"]) {
  for (const [name, spec] of Object.entries(pkg[field] ?? {})) {
    pkg[field][name] = lockedSpec(name, spec);
  }
}

writeFileSync("package.json", `${JSON.stringify(pkg, null, 2)}\n`);
process.stdout.write(
  `${JSON.stringify(
    {
      dependencies: pkg.dependencies ?? {},
      optionalDependencies: pkg.optionalDependencies ?? {},
      peerDependencies: pkg.peerDependencies ?? {},
    },
    null,
    2,
  )}\n`,
);
