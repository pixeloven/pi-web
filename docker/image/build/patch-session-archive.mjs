#!/usr/bin/env node
// Opt-in source transform (PI_WEB_STREAM_COPY_PATCH=true): replace the two
// fs.copyFile calls in src/server/sessions/sessionArchiveStore.ts with a
// userspace stream copy.
//
// On Linux, fs.copyFile uses copy_file_range(2). Some network or virtualized
// filesystems (for example virtiofs backed by NFS) reject it with EPERM, and
// libuv falls back to a plain copy only for ENOSYS, ENOTSUP, EXDEV, and EPERM on
// CIFS/SMB. Session archiving then fails. Local disks are not affected.
//
// The transform checks strict pre- and postconditions so an upstream change to
// those copy sites fails the build instead of silently applying nothing.

import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const STREAM_COPY_HELPER = `async function streamCopyFile(source: string, destination: string): Promise<void> {
  await pipeline(createReadStream(source), createWriteStream(destination));
}

`;

function exactlyOne(matches, description) {
  if (matches.length !== 1) {
    throw new Error(`expected exactly one ${description}; found ${matches.length}`);
  }
  return matches[0];
}

export function transformSessionArchiveStore(source) {
  if (source.includes("streamCopyFile")) {
    throw new Error("session archive source is already stream-copy aware");
  }

  const promiseImports = [...source.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']node:fs\/promises["'];/g)];
  const promiseImport = exactlyOne(
    promiseImports.filter((match) => match[1].split(",").map((name) => name.trim()).includes("copyFile")),
    "copyFile import from node:fs/promises",
  );
  const promiseNames = promiseImport[1].split(",").map((name) => name.trim()).filter(Boolean);
  const remainingPromiseNames = promiseNames.filter((name) => name !== "copyFile");
  if (remainingPromiseNames.length !== promiseNames.length - 1) {
    throw new Error("copyFile import was not unique");
  }

  const fsImport = exactlyOne(
    [...source.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']node:fs["'];/g)],
    "named import from node:fs",
  );
  const fsNames = fsImport[1].split(",").map((name) => name.trim()).filter(Boolean);
  if (fsNames.includes("createReadStream") || fsNames.includes("createWriteStream")) {
    throw new Error("node:fs stream imports already exist unexpectedly");
  }

  const copyCalls = [...source.matchAll(/await\s+copyFile\(([^;]+)\);/g)];
  if (copyCalls.length !== 2) {
    throw new Error(`expected exactly two awaited copyFile calls; found ${copyCalls.length}`);
  }

  const pathExistsMarker = "async function pathExists(";
  if (source.split(pathExistsMarker).length !== 2) {
    throw new Error("expected exactly one pathExists helper insertion point");
  }

  let transformed = source;
  const newPromiseImport = `import { ${remainingPromiseNames.join(", ")} } from "node:fs/promises";`;
  transformed = transformed.replace(
    promiseImport[0],
    newPromiseImport,
  );
  transformed = transformed.replace(
    fsImport[0],
    `import { ${[...fsNames, "createReadStream", "createWriteStream"].join(", ")} } from "node:fs";`,
  );
  transformed = transformed.replace(
    newPromiseImport,
    (match) => `${match}\nimport { pipeline } from "node:stream/promises";`,
  );
  transformed = transformed.replace(/await\s+copyFile\(/g, "await streamCopyFile(");
  transformed = transformed.replace(pathExistsMarker, `${STREAM_COPY_HELPER}${pathExistsMarker}`);

  const requiredFragments = [
    "createReadStream",
    "createWriteStream",
    'import { pipeline } from "node:stream/promises";',
    STREAM_COPY_HELPER.trim(),
  ];
  for (const fragment of requiredFragments) {
    if (!transformed.includes(fragment)) {
      throw new Error(`postcondition failed: missing ${fragment}`);
    }
  }
  if ((transformed.match(/await\s+streamCopyFile\(/g) ?? []).length !== 2) {
    throw new Error("postcondition failed: expected two streamCopyFile calls");
  }
  if (/await\s+copyFile\(/.test(transformed) || /\bcopyFile\b/.test(remainingPromiseNames.join(","))) {
    throw new Error("postcondition failed: copyFile remains active");
  }
  return transformed;
}

async function main() {
  const sourcePath = process.argv[2];
  if (!sourcePath) {
    throw new Error("usage: patch-session-archive.mjs <sessionArchiveStore.ts>");
  }
  const source = await readFile(sourcePath, "utf8");
  await writeFile(sourcePath, transformSessionArchiveStore(source));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
