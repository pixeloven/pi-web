// Runs inside the image (piped to `node --input-type=module -`) after
// `pi-web-container prepare`. Checks that Pi loads every image package from its
// /opt path and that the built-in bash tool runs in the container.
import assert from "node:assert/strict";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const piRoot = "/opt/pi-web/global/lib/node_modules/@earendil-works/pi-coding-agent";
const { DefaultResourceLoader, SettingsManager, createBashToolDefinition } = await import(
  `${piRoot}/dist/index.js`
);

const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME, ".pi/agent");
const image = JSON.parse(await readFile("/opt/pi-web/image.json", "utf8"));
const settings = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"));

assert.deepEqual(
  settings.packages.slice(0, image.piPackages.paths.length),
  image.piPackages.paths,
  "image packages are registered first, in image order",
);

const cwd = await mkdtemp(join(tmpdir(), "pi-web-contract-"));
try {
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager: SettingsManager.create(cwd, agentDir),
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
  });
  await loader.reload();
  const { extensions, errors } = loader.getExtensions();
  assert.deepEqual(errors, [], "image Pi packages load without errors");
  const loadedFrom = await Promise.all(extensions.map((extension) => realpath(extension.resolvedPath)));
  for (const path of image.piPackages.paths) {
    const root = await realpath(path);
    assert.ok(
      loadedFrom.some((file) => file.startsWith(`${root}/`)),
      `an extension loads from ${path}`,
    );
  }

  const bash = createBashToolDefinition(cwd);
  const result = await bash.execute(
    "pi-web-contract",
    { command: "printf PI_WEB_BASH_OK" },
    new AbortController().signal,
    undefined,
    undefined,
  );
  const output = result.content
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n");
  assert.match(output, /PI_WEB_BASH_OK/, "the bash tool runs commands");
} finally {
  await rm(cwd, { recursive: true, force: true });
}

console.log(`in-image checks passed (${image.piPackages.paths.length} image packages)`);
