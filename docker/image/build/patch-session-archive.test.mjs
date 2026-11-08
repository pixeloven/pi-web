import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import test from "node:test";

import { transformSessionArchiveStore } from "./patch-session-archive.mjs";

const FIXTURE = `import { constants } from "node:fs";
import { access, copyFile, mkdir, rename, unlink } from "node:fs/promises";

async function copySessionFileToArchive(source: string, archivePath: string): Promise<void> {
  await copyFile(source, archivePath);
}

async function moveFile(source: string, destination: string): Promise<void> {
  await copyFile(source, destination);
  await unlink(source);
}

async function pathExists(path: string): Promise<boolean> {
  await access(path, constants.F_OK);
  return true;
}
`;

test("replaces both archive copies with the userspace stream path", () => {
  const output = transformSessionArchiveStore(FIXTURE);
  assert.equal((output.match(/await streamCopyFile\(/g) ?? []).length, 2);
  assert.doesNotMatch(output, /await copyFile\(/);
  assert.match(output, /pipeline\(createReadStream\(source\), createWriteStream\(destination\)\)/);
});

test("refuses unexpected upstream call counts", () => {
  assert.throws(() => transformSessionArchiveStore(FIXTURE.replace("  await copyFile(source, destination);\n", "")), /exactly two/);
});

test("refuses a missing copyFile import", () => {
  assert.throws(() => transformSessionArchiveStore(FIXTURE.replace("copyFile, ", "")), /exactly one copyFile import/);
});

test("refuses already-patched input", () => {
  assert.throws(() => transformSessionArchiveStore(FIXTURE.replaceAll("copyFile", "streamCopyFile")), /already stream-copy aware/);
});

test("stream pipeline preserves representative JSONL bytes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pi-web-archive-copy-"));
  try {
    const source = join(directory, "source.jsonl");
    const destination = join(directory, "destination.jsonl");
    const content = '{"role":"user","content":"hello"}\n{"role":"assistant","content":"world 🌍"}\n';
    await writeFile(source, content);
    await pipeline(createReadStream(source), createWriteStream(destination));
    assert.equal(await readFile(destination, "utf8"), content);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
