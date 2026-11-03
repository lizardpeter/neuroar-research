#!/usr/bin/env node
/**
 * Read-only App Store Connect preflight for a TestFlight upload.
 * Uses the Team API key already stored as an environment secret.
 * No JWT or private key material is printed or written to GitHub artifacts.
 */
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";

const {
  APPSTORE_ISSUER_ID: issuer,
  APPSTORE_API_KEY_ID: keyId,
  APPSTORE_BUNDLE_ID: bundle,
  ASC_AUTH_KEY_PATH: keyPath,
} = process.env;
if (![issuer, keyId, bundle, keyPath].every(Boolean)) {
  console.error("::error::Missing App Store Connect preflight configuration.");
  process.exit(1);
}
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const header = b64({ alg: "ES256", kid: keyId, typ: "JWT" });
const claims = b64({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" });
const toSign = header + "." + claims;
let token;
try {
  const key = createPrivateKey(readFileSync(keyPath));
  const signature = sign("sha256", Buffer.from(toSign), {
    key,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
  token = toSign + "." + signature;
} catch {
  console.error("::error::Unable to sign Apple API request. Check APPSTORE_API_PRIVATE_KEY.");
  process.exit(1);
}
const url = new URL("https://api.appstoreconnect.apple.com/v1/apps");
url.searchParams.set("filter[bundleId]", bundle);
url.searchParams.set("limit", "10");
try {
  const response = await fetch(url, {
    headers: { Authorization: "Bearer " + token, Accept: "application/json" },
    signal: AbortSignal.timeout(25000),
  });
  if (!response.ok) {
    console.error("::error::Apple API preflight returned HTTP " + response.status +
      ". Verify that your Team API key is active and authorized. Key contents were not logged.");
    process.exit(1);
  }
  const payload = await response.json();
  const matched = (payload.data || []).find(
    (app) => app.attributes?.bundleId === bundle
  );
  if (!matched) {
    console.error("::error::App Store Connect has no app record for " + bundle +
      ". Create NeuroAR Research under App Store Connect > Apps > New App, " +
      "selecting the same registered Bundle ID. No Xcode installation needed.");
    process.exit(1);
  }
  console.log("Verified App Store Connect app record: " +
    matched.attributes.name + " (" + bundle + ").");
} catch (error) {
  if (error?.message && !error.message.includes("preflight")) {
    console.error("::error::Could not verify the App Store Connect app record: " +
      error.name + ". Review Apple API availability and permissions.");
  }
  process.exit(1);
}
