import { test } from "node:test";
import assert from "node:assert/strict";
import { meetsMinVersion, withinMaxVersion } from "../lib/payload.js";

// The max gate exists for one launch scenario: a "Aaavatar 2 is out" notice
// that only 1.x installs should see. v1 never sends X-App-Version, so a
// missing header must pass max (old client) and fail min (unknown feature
// support) — the two gates deliberately disagree on `null`.

test("withinMaxVersion: no max → always true", () => {
  assert.equal(withinMaxVersion("1.2.1", null), true);
  assert.equal(withinMaxVersion(null, null), true);
});

test("withinMaxVersion: missing version header counts as an old client", () => {
  assert.equal(withinMaxVersion(null, "1.99"), true);
  assert.equal(meetsMinVersion(null, "1.99"), false);
});

test("withinMaxVersion: 1.x passes a 1.99 cap, 2.x does not", () => {
  assert.equal(withinMaxVersion("1.2.1", "1.99"), true);
  assert.equal(withinMaxVersion("1.99", "1.99"), true);
  assert.equal(withinMaxVersion("1.99.1", "1.99"), false);
  assert.equal(withinMaxVersion("2.0.0", "1.99"), false);
  assert.equal(withinMaxVersion("2.0.0", "2.0"), true);
  assert.equal(withinMaxVersion("10.0", "9.9"), false);
});

test("withinMaxVersion: unparseable segments fall back to 0 like meetsMinVersion", () => {
  assert.equal(withinMaxVersion("1.x", "1.99"), true);
  assert.equal(withinMaxVersion("banana", "1.99"), true);
});

// E13.8 (2026-09-06): the same max gate on /v1/messages reaches only the
// 2.0.0/2.0.1 installs that lack Sparkle's sandbox entitlements and must
// reinstall the DMG by hand. 2.0.2+ (fixed) must never see that message.
test("withinMaxVersion: a 2.0.1 cap keeps 2.0.0/2.0.1 and drops 2.0.2+", () => {
  assert.equal(withinMaxVersion("2.0.0", "2.0.1"), true);
  assert.equal(withinMaxVersion("2.0.1", "2.0.1"), true);
  assert.equal(withinMaxVersion("2.0.2", "2.0.1"), false);
  assert.equal(withinMaxVersion("2.1.0", "2.0.1"), false);
});
