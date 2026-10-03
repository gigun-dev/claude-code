import { createRemoteJWKSet, jwtVerify } from "jose";
const enc = new TextEncoder();
const noCache = {
  "Cache-Control": "private, no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};
const escape = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const b64 = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
const unb64 = (s) =>
  Uint8Array.from(
    atob(
      s.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - (s.length % 4)) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
const key = (secret) =>
  crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
export async function signedURL(origin, path, secret, now = Date.now()) {
  const expires = String(Math.floor(now / 1000) + 600);
  const signature = b64(
    await crypto.subtle.sign(
      "HMAC",
      await key(secret),
      enc.encode(`${origin}${path}\n${expires}`),
    ),
  );
  return `${origin}${path}?expires=${expires}&signature=${signature}`;
}
export async function validDownload(url, secret, now = Date.now()) {
  const expires = url.searchParams.get("expires"),
    signature = url.searchParams.get("signature"),
    seconds = Math.floor(now / 1000);
  if (
    !/^\d+$/.test(expires || "") ||
    Number(expires) <= seconds ||
    Number(expires) > seconds + 600 ||
    !/^[\w-]{43}$/.test(signature || "")
  )
    return false;
  try {
    return await crypto.subtle.verify(
      "HMAC",
      await key(secret),
      unb64(signature),
      enc.encode(`${url.origin}${url.pathname}\n${expires}`),
    );
  } catch {
    return false;
  }
}
const jwksCache = new Map();
async function authenticated(request, env) {
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token || !env.ACCESS_AUD || !env.ACCESS_ISSUER) return false;
  try {
    let keys = jwksCache.get(env.ACCESS_ISSUER);
    if (!keys) {
      keys = createRemoteJWKSet(
        new URL(`${env.ACCESS_ISSUER}/cdn-cgi/access/certs`),
      );
      jwksCache.set(env.ACCESS_ISSUER, keys);
    }
    await jwtVerify(token, keys, {
      issuer: env.ACCESS_ISSUER,
      audience: env.ACCESS_AUD,
      algorithms: ["RS256"],
    });
    return true;
  } catch {
    return false;
  }
}
const html = (body) =>
  new Response(
    `<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>アプリ配布</title><style>body{font:17px system-ui;max-width:640px;margin:48px auto;padding:0 24px;line-height:1.6}a,button{color:#06c}button{font:inherit;padding:12px 24px;border-radius:12px;border:1px solid #06c;background:#fff}li{margin:16px 0}small{color:#666}</style>${body}</html>`,
    {
      headers: {
        ...noCache,
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy":
          "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
      },
    },
  );
async function readJSON(bucket, path) {
  const obj = await bucket.get(path);
  return obj ? await obj.json() : null;
}
export async function handle(request, env, authenticate = authenticated) {
  const url = new URL(request.url);
  if (url.origin !== env.PUBLIC_ORIGIN)
    return new Response("Not found", { status: 404 });
  if (!["GET", "HEAD"].includes(request.method))
    return new Response("Method not allowed", { status: 405 });
  // Restrict installer transport to immutable releases; never expose an arbitrary R2 key.
  const download = url.pathname.match(
    /^\/download\/([a-z0-9-]+)\/([a-f0-9]{64})\/(app\.ipa|app\.apk|manifest\.plist)$/,
  );
  if (url.pathname.startsWith("/download/")) {
    if (!download || !(await validDownload(url, env.DOWNLOAD_SECRET)))
      return new Response("Download link expired or invalid", {
        status: 403,
        headers: noCache,
      });
    const [, slug, release, file] = download,
      prefix = `${slug}/releases/${release}`;
    if (file === "manifest.plist") {
      const info = await readJSON(env.ARTIFACTS, `${prefix}/release.json`);
      if (!info || !info.ios) return new Response("Not found", { status: 404 });
      const ipa = await signedURL(
        url.origin,
        `/download/${slug}/${release}/app.ipa`,
        env.DOWNLOAD_SECRET,
      );
      const xml = `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${escape(ipa)}</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>${escape(info.bundleId)}</string><key>bundle-version</key><string>${escape(info.version)}</string><key>kind</key><string>software</string><key>title</key><string>${escape(info.name)}</string></dict></dict></array></dict></plist>`;
      return new Response(request.method === "HEAD" ? null : xml, {
        headers: { ...noCache, "Content-Type": "application/xml" },
      });
    }
    const object = await env.ARTIFACTS.get(
      `${prefix}/${file}`,
      request.headers.has("Range") ? { range: request.headers } : {},
    );
    if (!object) return new Response("Not found", { status: 404 });
    const headers = new Headers(noCache);
    object.writeHttpMetadata(headers);
    headers.set("Content-Type", "application/octet-stream");
    headers.set("ETag", object.httpEtag);
    let status = 200;
    if (
      request.headers.has("Range") &&
      object.range &&
      "offset" in object.range
    ) {
      status = 206;
      headers.set(
        "Content-Range",
        `bytes ${object.range.offset}-${object.range.offset + object.range.length - 1}/${object.size}`,
      );
      headers.set("Content-Length", String(object.range.length));
    } else headers.set("Content-Length", String(object.size));
    headers.set("Accept-Ranges", "bytes");
    return new Response(request.method === "HEAD" ? null : object.body, {
      status,
      headers,
    });
  }
  if (!(await authenticate(request, env)))
    return new Response("Access login required", {
      status: 401,
      headers: noCache,
    });
  if (url.pathname === "/") {
    const list = await env.ARTIFACTS.list({ delimiter: "/", limit: 100 });
    const apps = (
      await Promise.all(
        list.delimitedPrefixes.map((p) =>
          readJSON(env.ARTIFACTS, `${p}latest.json`),
        ),
      )
    ).filter(Boolean);
    return html(
      `<h1>検証用アプリ</h1><ul>${apps.map((a) => `<li><a href="/${escape(a.slug)}/">${escape(a.name)}</a><br><small>バージョン ${escape(a.version)} · ${escape(a.publishedAt)}</small></li>`).join("")}</ul>`,
    );
  }
  const app = url.pathname.match(/^\/([a-z0-9-]+)\/(install)?$/);
  if (!app) return new Response("Not found", { status: 404 });
  const [, slug, install] = app,
    info = await readJSON(env.ARTIFACTS, `${slug}/latest.json`);
  if (!info || !/^[a-f0-9]{64}$/.test(info.release))
    return new Response("Not found", { status: 404 });
  if (install) {
    const android = url.searchParams.get("platform") === "android";
    if (android ? !info.android : !info.ios)
      return new Response("Not found", { status: 404 });
    const file = android ? "app.apk" : "manifest.plist";
    const target = await signedURL(
      url.origin,
      `/download/${slug}/${info.release}/${file}`,
      env.DOWNLOAD_SECRET,
    );
    return Response.json(
      {
        url: !android
          ? `itms-services://?action=download-manifest&url=${encodeURIComponent(target)}`
          : target,
      },
      { headers: noCache },
    );
  }
  return html(
    `<a href="/">← アプリ一覧</a><h1>${escape(info.name)}</h1><p>バージョン ${escape(info.version)}</p><p>${escape(info.message || "")}</p>${info.ios ? `<button data-platform="ios">iPhone・iPadにインストール</button>` : ""}${info.android ? `<button data-platform="android">Androidにダウンロード</button>` : ""}<p id="status"></p><p><small>iOSはSafariで開いてください。登録済み端末で利用できます。</small></p><a href="x-safari-https://${escape(url.host + url.pathname)}">Safariで開く</a><script>document.querySelectorAll('button[data-platform]').forEach(b=>b.onclick=async()=>{const s=document.getElementById('status');s.textContent='準備中…';try{const r=await fetch('install?platform='+b.dataset.platform,{cache:'no-store'});if(!r.ok)throw Error();const d=await r.json();s.textContent='インストールの確認画面に進みます';location.href=d.url;}catch{s.textContent='リンクを発行できませんでした。ページを再読み込みしてください';}});</script>`,
  );
}
export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch {
      console.error(
        JSON.stringify({
          event: "ota_request_failed",
          path: new URL(request.url).pathname,
        }),
      );
      return new Response("Distribution temporarily unavailable", {
        status: 503,
        headers: noCache,
      });
    }
  },
};
