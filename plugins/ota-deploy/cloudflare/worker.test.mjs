import { test } from "node:test";
import assert from "node:assert/strict";
import { signedURL, validDownload, handle } from "./worker.mjs";
const origin = "https://ota.example.invalid",
  secret = "fixture-secret-".repeat(4),
  release = "a".repeat(64);
const info = {
  slug: "test",
  name: "Test <app>",
  version: "1",
  bundleId: "dev.test",
  release,
  ios: true,
  publishedAt: "now",
};
const bucket = {
  async get(k) {
    return k.endsWith(".json") ? { json: async () => info } : null;
  },
  async list() {
    return { delimitedPrefixes: ["test/"] };
  },
};
const env = {
  PUBLIC_ORIGIN: origin,
  DOWNLOAD_SECRET: secret,
  ARTIFACTS: bucket,
};
test("signed link binds origin/path/expiry and rejects tampering", async () => {
  const now = 1700000000000,
    u = new URL(
      await signedURL(
        origin,
        "/download/test/" + release + "/app.ipa",
        secret,
        now,
      ),
    );
  assert.equal(await validDownload(u, secret, now), true);
  assert.equal(await validDownload(u, secret, now + 600000), false);
  for (const edit of [
    (x) => (x.hostname = "attacker.invalid"),
    (x) => (x.pathname = x.pathname.replace("app.ipa", "manifest.plist")),
    (x) => x.searchParams.set("expires", "1700001000"),
    (x) => x.searchParams.set("signature", "x".repeat(43)),
  ]) {
    const v = new URL(u);
    edit(v);
    assert.equal(await validDownload(v, secret, now), false);
  }
});
test("authentication is required for list, app and URL issuance", async () => {
  for (const p of ["/", "/test/", "/test/install"])
    assert.equal((await handle(new Request(origin + p), env)).status, 401);
  assert.equal(
    (
      await handle(
        new Request("https://elsewhere.invalid/"),
        env,
        async () => true,
      )
    ).status,
    404,
  );
  const listing = await handle(
    new Request(origin + "/"),
    env,
    async () => true,
  );
  assert.match(await listing.text(), /Test &lt;app&gt;/);
});
test("installer gets a signed manifest without browser cookies, with a separately signed IPA", async () => {
  const response = await handle(
    new Request(origin + "/test/install"),
    env,
    async () => true,
  );
  const link = (await response.json()).url;
  const manifest = new URL(link).searchParams.get("url");
  const xml = await handle(new Request(manifest), env);
  assert.equal(xml.status, 200);
  assert.match(await xml.text(), /bundle-identifier/);
  const invalid = new URL(manifest);
  invalid.searchParams.delete("signature");
  assert.equal((await handle(new Request(invalid), env)).status, 403);
  assert.equal(
    (await handle(new Request(origin + "/download/test/latest.json"), env))
      .status,
    403,
  );
});

test("Android can be selected when both artifacts exist", async () => {
  const both = { ...info, android: true };
  const e = {
    ...env,
    ARTIFACTS: { ...bucket, get: async () => ({ json: async () => both }) },
  };
  const result = await handle(
    new Request(origin + "/test/install?platform=android"),
    e,
    async () => true,
  );
  assert.match((await result.json()).url, /app\.apk/);
});
