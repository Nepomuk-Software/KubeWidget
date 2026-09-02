#!/usr/bin/env python3
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "list_kubeconfigs.py"
sys.path.insert(0, str(ROOT))
import list_kubeconfigs as lk  # noqa: E402

YAML = """apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: QQ==
    server: https://127.0.0.1:6443
  name: kind-kind
contexts:
- context:
    cluster: kind-kind
    namespace: kube-system
    user: kind-kind
  name: kind-kind
current-context: kind-kind
users:
- name: kind-kind
  user:
    client-certificate-data: QQ==
    client-key-data: QQ==
"""

JSON = """{
  "apiVersion": "v1",
  "kind": "Config",
  "clusters": [{"name": "c", "cluster": {"server": "https://example.test:443"}}],
  "contexts": [{"name": "prod", "context": {"cluster": "c", "namespace": "apps"}}],
  "current-context": "prod",
  "users": [{"name": "u", "user": {"token": "nope"}}]
}
"""

EVIL = """apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://127.0.0.1:1
  name: evil
contexts:
- context:
    cluster: evil
    user: evil
  name: evil
current-context: evil
users:
- name: evil
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: /bin/sh
      args:
        - -c
        - echo pwned > "{marker}"
"""


def run_lister(home: Path, env: dict | None = None) -> str:
    merged = os.environ.copy()
    merged["HOME"] = str(home)
    merged.pop("KUBECONFIG", None)
    if env:
        merged.update(env)
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        check=True,
        capture_output=True,
        text=True,
        env=merged,
    )
    return result.stdout


class ListKubeconfigsTest(unittest.TestCase):
    def test_yaml_and_json_and_skips_junk(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            kube = home / ".kube"
            kube.mkdir()
            (kube / "config").write_text(YAML)
            (kube / "extra.json").write_text(JSON)
            (kube / "cache").mkdir()
            (kube / "cache" / "discovery.json").write_text(JSON)
            (kube / "notes.lock").write_text(YAML)
            (kube / "empty").write_text("")
            out = run_lister(home)
            self.assertIn("file=%s\n" % (kube / "config").resolve(), out)
            self.assertIn("ctx=kind-kind|kind-kind|kube-system\n", out)
            self.assertIn("cluster=kind-kind|https://127.0.0.1:6443\n", out)
            self.assertIn("ctx=prod|c|apps\n", out)
            self.assertNotIn("discovery.json", out)
            self.assertNotIn("notes.lock", out)
            self.assertNotIn("token", out)
            self.assertNotIn("client-key-data", out)

    def test_exec_plugin_is_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            kube = home / ".kube"
            kube.mkdir()
            marker = kube / "pwned"
            (kube / "config").write_text(YAML)
            (kube / "evil.yaml").write_text(EVIL.format(marker=marker))
            out = run_lister(home)
            self.assertIn("ctx=evil|evil|default\n", out)
            self.assertFalse(marker.exists(), out)

    def test_does_not_invoke_kubectl(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            kube = home / ".kube"
            kube.mkdir()
            (kube / "config").write_text(YAML)
            (kube / "evil.yaml").write_text(EVIL.format(marker=kube / "pwned"))
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            invoked = home / "kubectl-invoked"
            kubectl = bin_dir / "kubectl"
            kubectl.write_text("#!/bin/sh\necho invoked >> '%s'\nexit 1\n" % invoked)
            kubectl.chmod(0o755)
            out = run_lister(home, {"PATH": str(bin_dir)})
            self.assertIn("ctx=kind-kind|kind-kind|kube-system\n", out)
            self.assertIn("ctx=evil|evil|default\n", out)
            self.assertFalse(invoked.exists(), "kubectl was invoked:\n%s" % out)
            self.assertNotIn("nokubectl=1", out)

    def test_kubectl_config_view_would_not_be_needed(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            kube = home / ".kube"
            kube.mkdir()
            (kube / "config").write_text(YAML)
            env = os.environ.copy()
            env["HOME"] = str(home)
            env.pop("KUBECONFIG", None)
            env["PATH"] = "/usr/bin:/bin"
            out = subprocess.run(
                [sys.executable, str(SCRIPT)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            ).stdout
            self.assertIn("ctx=kind-kind|kind-kind|kube-system\n", out)

    def test_kubeconfig_env_sets_default_and_lists_colon_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            a = home / "a.yaml"
            b = home / "b.yaml"
            a.write_text(YAML)
            b.write_text(JSON)
            out = run_lister(home, {"KUBECONFIG": "%s:%s" % (a, b)})
            self.assertIn("defaultfile=%s\n" % a.resolve(), out)
            self.assertIn("ctx=kind-kind|kind-kind|kube-system\n", out)
            self.assertIn("ctx=prod|c|apps\n", out)

    def test_simple_parser_handles_kubectl_layout(self):
        doc = lk.parse_simple_yaml(YAML)
        current, contexts, servers = lk.extract(doc)
        self.assertEqual(current, "kind-kind")
        self.assertEqual(contexts, [("kind-kind", "kind-kind", "kube-system")])
        self.assertEqual(servers["kind-kind"], "https://127.0.0.1:6443")

    def test_simple_parser_ignores_users_exec(self):
        marker = "/tmp/should-not-exist-kubecontext-test"
        doc = lk.parse_simple_yaml(EVIL.format(marker=marker))
        current, contexts, servers = lk.extract(doc)
        self.assertEqual(current, "evil")
        self.assertEqual(contexts[0][0], "evil")
        dumped = str(doc)
        # The subset parser may still see the users section if indent-0
        # handling fails; extract() must not surface command/args.
        self.assertNotIn("command", "".join(name + cluster for name, cluster, _ in contexts))
        self.assertEqual(servers["evil"], "https://127.0.0.1:1")

    def test_refuses_unreadable_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            kube = home / ".kube"
            kube.mkdir()
            secret = kube / "secret"
            secret.write_text(YAML)
            secret.chmod(0)
            try:
                out = run_lister(home)
                self.assertNotIn("kind-kind", out)
            finally:
                secret.chmod(stat.S_IRUSR | stat.S_IWUSR)


if __name__ == "__main__":
    unittest.main()
