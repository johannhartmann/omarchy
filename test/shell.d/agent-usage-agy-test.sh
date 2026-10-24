#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3

# Regression fixtures extend the collector scenarios from ashxddaga's PR
# #15056. No credentials, installed CLIs, or real user data are accessed.
python3 - "$ROOT" <<'PY'
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

root = Path(sys.argv[1])
loader = importlib.machinery.SourceFileLoader("agy_usage", str(root / "bin/omarchy-agent-usage-agy"))
spec = importlib.util.spec_from_loader(loader.name, loader)
agy = importlib.util.module_from_spec(spec)
loader.exec_module(agy)


class UsageTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.home = Path(self.tmp.name)
    self.env = patch.dict(os.environ, {"HOME": str(self.home), "XDG_CACHE_HOME": str(self.home / "cache"),
                                     "XDG_STATE_HOME": str(self.home / "state"), "AGY_ADC_AUTH": "", "TZ": "UTC"})
    self.env.start()
    self.addCleanup(self.env.stop)
    time.tzset()
    self.data = agy.get_agy_dir()
    self.data.mkdir(parents=True)
    self.today = dt.date.today().isoformat()
    self.yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()

  def write_lines(self, path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n{partial")

  def scan(self):
    return agy.scan_local_stats(self.data, self.today, [self.yesterday, self.today])

  def quota(self, remaining=0.8):
    return {"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": [
      {"name": "Gemini Models", "buckets": [{"window": "5h", "remaining_fraction": remaining,
                                                "reset_time": "2026-10-25T00:00:00Z"}]}
    ]}}}

  def probe(self, payload=None, code=0, error="", exception=None):
    completed = subprocess.CompletedProcess([], code, json.dumps(payload or {}), error)
    with patch.object(agy.subprocess, "run", side_effect=exception, return_value=completed) as run:
      result = agy.probe_authoritative_limits(self.data, "/native/agy")
    return result, run

  def main(self, *args, binary=None):
    output = io.StringIO()
    with patch.object(sys, "argv", ["agy-usage", *args]), patch.object(agy, "get_agy_bin", return_value=binary), contextlib.redirect_stdout(output):
      code = agy.main()
    return code, json.loads(output.getvalue()) if output.getvalue() else None

  def test_missing_and_unused_install(self):
    _, record = self.main()
    self.assertFalse(record["ready"])
    self.assertEqual(record["limits"], [])
    self.assertFalse((self.data / "conversation_summaries.db").exists())
    with patch.object(agy.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
      _, record = self.main(binary="/native/agy")
    self.assertFalse(record["ready"])

  def test_history_dates_and_duplicates(self):
    row = {"timestamp": self.today + "T10:00:00Z", "prompt": "today"}
    self.write_lines(self.data / "history.jsonl", [row, row, {"timestamp": "broken"},
      {"timestamp": self.today + "T00:30:00+02:00", "prompt": "yesterday in UTC"}, [], None])
    stats = self.scan()
    self.assertEqual((stats["todayPrompts"], stats["totalPrompts"]), (1, 2))
    self.assertEqual(stats["activeDates"], [self.yesterday, self.today])

  def test_root_sessions_read_only_and_corrupt_db(self):
    db = self.data / "conversation_summaries.db"
    with sqlite3.connect(db) as conn:
      conn.execute("CREATE TABLE conversation_summaries (conversation_id TEXT, parent_conversation_id TEXT, last_modified_time TEXT)")
      conn.executemany("INSERT INTO conversation_summaries VALUES (?, ?, ?)", [
        ("root", "", self.today + "T00:30:00Z"), ("old", None, self.yesterday + "T12:00:00Z"),
        ("child", "root", self.today + "T12:00:00Z")])
    before = db.read_bytes()
    stats = self.scan()
    self.assertEqual((stats["todaySessions"], stats["totalSessions"]), (1, 2))
    self.assertEqual(db.read_bytes(), before)
    db.write_text("corrupt")
    self.assertEqual(self.scan()["totalSessions"], 0)

  def test_token_snapshots_models_and_unknown_dates(self):
    first = {"step_index": 1, "created_at": self.today + "T10:00:00Z", "model": "old-model",
             "input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 10}
    last = dict(first, input_tokens=200)
    self.write_lines(self.data / "brain/one/transcript.jsonl", [first, last,
      {"step_index": 2, "created_at": self.yesterday + "T10:00:00Z", "model": "new-model", "input_tokens": 30, "output_tokens": 5},
      {"step_index": 3, "created_at": "invalid", "input_tokens": 7, "output_tokens": 2},
      {"step_index": 4, "input_tokens": -100, "output_tokens": "bad"}])
    (self.data / "settings.json").write_text('{"model":"current-model"}')
    stats = self.scan()
    self.assertEqual(stats["todayTotalTokens"], 220)
    self.assertEqual([d["messageCount"] for d in stats["recentDays"]], [35, 220])
    self.assertEqual(stats["todayTokensByModel"], {"old-model": 220})
    self.assertNotIn("current-model", stats["modelUsage"])
    self.assertEqual(stats["modelUsage"]["old-model"]["inputTokens"], 190)
    self.assertEqual(stats["modelUsage"]["unknown"]["inputTokens"], 7)

  def test_quota_parser_rejects_invalid_values_and_noncommands(self):
    self.assertEqual(agy.parse_limits(self.quota())[0]["percent"], 0.2)
    quota = self.quota()
    quota["command"]["data"]["groups"].append({"name": "Claude and GPT models", "buckets": [
      {"window": "5h", "remaining_fraction": 0.4}]})
    self.assertEqual([limit["title"] for limit in agy.parse_limits(quota)], ["Session", "Claude and GPT models Session"])
    for value in [None, "oops", float("nan"), float("inf"), -1, 2]:
      self.assertEqual(agy.parse_limits(self.quota(value)), [])
    with self.assertRaises(ValueError):
      agy.parse_limits({"status": "SUCCESS", "response": "model answer"})

  def test_native_probe_is_bounded_and_always_expands_slash_commands(self):
    result, run = self.probe(self.quota())
    self.assertEqual(result["limits"][0]["percent"], 0.2)
    self.assertGreater(result["fetchedAtMs"], 0)
    self.assertIn("--disable-slash-commands=false", run.call_args.args[0])
    self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)
    self.assertEqual(run.call_args.kwargs["timeout"], 20)
    self.assertEqual(run.call_args.kwargs["env"]["BROWSER"], "true")
    # A shared-keyring account may have changed since the previous probe.
    result, run = self.probe(self.quota(0.4))
    run.assert_called_once()
    self.assertEqual(result["limits"][0]["percent"], 0.6)

  def test_network_fallback_and_authentication_invalidation(self):
    fresh, _ = self.probe(self.quota())
    failed, _ = self.probe(exception=subprocess.TimeoutExpired("agy", 20))
    self.assertTrue(failed["stale"])
    self.assertEqual(failed["fetchedAtMs"], fresh["fetchedAtMs"])
    signed_out, _ = self.probe(code=1, error="Unauthenticated; sign in https://secret.invalid")
    self.assertEqual(signed_out["usageStatusText"], "Waiting for auth")
    self.assertEqual(signed_out["limits"], [])
    self.assertNotIn("secret.invalid", json.dumps(signed_out))
    failed, _ = self.probe(exception=subprocess.TimeoutExpired("agy", 20))
    self.assertEqual(failed["limits"], [])
    self.probe(self.quota())
    with patch.object(agy.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "not JSON", "oauth2: invalid_grant")):
      expired = agy.probe_authoritative_limits(self.data, "/native/agy")
    self.assertEqual(expired["usageStatusText"], "Sign-in expired")
    self.assertEqual(expired["limits"], [])

  def test_malformed_probe_and_different_home_do_not_replay_quotas(self):
    self.probe(self.quota())
    result, _ = self.probe({"status": "SUCCESS", "command": {"name": "usage", "data": []}})
    self.assertEqual(result["limits"], [])
    with patch.object(agy.subprocess, "run", side_effect=subprocess.TimeoutExpired("agy", 20)):
      result = agy.probe_authoritative_limits(self.home / "different", "/native/agy")
    self.assertEqual(result["limits"], [])

  def test_api_key_and_adc_do_not_probe_subscription(self):
    for settings, adc in [({"modelProvider": "gemini"}, ""), ({}, "true")]:
      (self.data / "settings.json").write_text(json.dumps(settings))
      with patch.dict(os.environ, {"AGY_ADC_AUTH": adc}), patch.object(agy.subprocess, "run") as run:
        result = agy.probe_authoritative_limits(self.data, "/native/agy")
      run.assert_not_called()
      self.assertEqual(result["usageStatusText"], "Limits paused")

  def test_local_cache_reuse_midnight_and_force(self):
    history = self.data / "history.jsonl"
    self.write_lines(history, [{"timestamp": self.today + "T10:00:00Z"}])
    _, first = self.main()
    self.write_lines(history, [{"timestamp": self.today + "T10:00:00Z"}, {"timestamp": self.today + "T11:00:00Z"}])
    _, reused = self.main("--limits-only")
    self.assertEqual(reused["totalPrompts"], first["totalPrompts"])
    cache = agy.cache_file(self.data, "stats")
    data = json.loads(cache.read_text())
    data["day"] = self.yesterday
    cache.write_text(json.dumps(data))
    _, refreshed = self.main("--limits-only")
    self.assertEqual(refreshed["totalPrompts"], 2)
    self.write_lines(history, [])
    _, forced = self.main("--limits-only", "--force")
    self.assertEqual(forced["totalPrompts"], 0)

  def test_atomic_state_write_and_unwritable_cache(self):
    bad_cache = self.home / "bad-cache"
    bad_cache.touch()
    with patch.dict(os.environ, {"XDG_CACHE_HOME": str(bad_cache)}):
      code, record = self.main("--write")
    state = self.home / "state/omarchy/agents/usage/agy.json"
    self.assertEqual(code, 0)
    self.assertEqual(json.loads(state.read_text()), record)
    self.assertEqual(state.stat().st_mode & 0o777, 0o600)
    blocked = self.home / "blocked"
    blocked.touch()
    with patch.dict(os.environ, {"XDG_STATE_HOME": str(blocked)}), contextlib.redirect_stderr(io.StringIO()):
      self.assertEqual(self.main("--write")[0], 1)

  def test_lazy_launcher_never_installs(self):
    binary = self.home / "bin/agy"
    binary.parent.mkdir()
    binary.write_text('#!/bin/bash\nmise use -g antigravity-cli\n')
    binary.chmod(0o755)
    with patch.dict(os.environ, {"PATH": str(binary.parent)}), patch.object(agy.subprocess, "run") as run:
      self.assertIsNone(agy.get_agy_bin())
    run.assert_not_called()

  def test_updater_discovers_real_collector_and_accepts_refresh_flags(self):
    tools = self.home / "tools"
    tools.mkdir()
    (tools / "agy").write_text("#!/bin/bash\nprintf '%s\\n' '" + json.dumps(self.quota()) + "'\n")
    (tools / "agy").chmod(0o755)
    source = self.home / "source/bin"
    source.mkdir(parents=True)
    (source / "omarchy-agent-usage-agy").symlink_to(root / "bin/omarchy-agent-usage-agy")
    env = dict(os.environ, OMARCHY_PATH=str(source.parent), PATH=str(tools) + ":/usr/bin:/bin")
    for flags in [("--force", "agy"), ("--limits-only", "agy")]:
      completed = subprocess.run([str(root / "bin/omarchy-agent-usage-update"), *flags],
                                 capture_output=True, text=True, env=env, timeout=10)
      self.assertEqual(completed.returncode, 0, completed.stderr)
      record = json.loads((self.home / "state/omarchy/agents/usage/agy.json").read_text())
      self.assertTrue(record["ready"])
      self.assertEqual(record["limits"][0]["percent"], 0.2)

unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
pass "Antigravity usage, native quotas, cache isolation, and failure fixtures"
