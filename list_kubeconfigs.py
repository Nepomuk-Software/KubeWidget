#!/usr/bin/env python3
"""List kubeconfig contexts without invoking kubectl.

kubectl against an untrusted kubeconfig can run users.exec credential
plugins. This script only reads files and prints context names, cluster
names and server URLs. It never looks at users, never execs, and never
talks to a cluster.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

MAX_FILE = 1_048_576
MAX_CONTEXTS = 256
MAX_FIELD = 512
SKIP_EXACT = {"cache", "http", "discovery"}
SKIP_SUFFIX = (".lock", ".tmp", ".swp")


def clamp(value: object, max_len: int = MAX_FIELD) -> str:
    text = "" if value is None else str(value)
    text = "".join(ch for ch in text if ch >= " " or ch in "\t")
    return text[:max_len]


def load_doc(text: str):
    stripped = text.lstrip("\ufeff").lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        doc = json.loads(text)
        return doc if isinstance(doc, dict) else None
    try:
        import yaml  # type: ignore

        doc = yaml.safe_load(text)
        return doc if isinstance(doc, dict) else None
    except Exception:
        return parse_simple_yaml(text)


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    if value in ("|", ">", "|-", ">-", "|+", ">+"):
        return ""
    return value


def parse_simple_yaml(text: str) -> dict:
    """kubectl-style kubeconfig subset: current-context, contexts, clusters."""
    data: dict = {"current-context": "", "contexts": [], "clusters": []}
    section = None
    item: dict | None = None
    sub: dict | None = None
    item_indent = 0

    for raw in text.splitlines():
        if len(raw) > 8192:
            raw = raw[:8192]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or stripped == "---":
            continue
        indent = len(raw) - len(raw.lstrip(" "))

        if indent == 0 and not stripped.startswith("-"):
            if item is not None and section in ("contexts", "clusters"):
                data[section].append(item)
            item = None
            sub = None
            key, sep, rest = stripped.partition(":")
            key = key.strip()
            if not sep:
                section = "skip"
                continue
            if key == "current-context":
                data["current-context"] = _unquote(rest)
                section = None
            elif key in ("contexts", "clusters"):
                section = key
            else:
                section = "skip"
            continue

        if section not in ("contexts", "clusters"):
            continue

        if stripped.startswith("-"):
            if item is not None:
                data[section].append(item)
            item = {}
            sub = None
            item_indent = indent
            rest = stripped[1:].strip()
            if rest:
                key, sep, value = rest.partition(":")
                if sep:
                    nested = _mapping_key(key)
                    if nested and not value.strip():
                        sub = {}
                        item[nested] = sub
                    else:
                        item[key.strip()] = _unquote(value)
            continue

        if item is None:
            continue

        key, sep, value = stripped.partition(":")
        if not sep:
            continue
        key = key.strip()
        nested = _mapping_key(key)
        if indent <= item_indent:
            continue
        if nested and not value.strip() and indent <= item_indent + 4:
            sub = {}
            item[nested] = sub
            continue
        if sub is not None and indent > item_indent + 2:
            sub[key] = _unquote(value)
        else:
            item[key] = _unquote(value)
            if key == "name":
                sub = None

    if item is not None and section in ("contexts", "clusters"):
        data[section].append(item)
    return data


def _mapping_key(key: str) -> str | None:
    key = key.strip()
    if key == "context":
        return "context"
    if key == "cluster":
        return "cluster"
    return None


def extract(doc: dict) -> tuple[str, list[tuple[str, str, str]], dict[str, str]]:
    current = clamp(doc.get("current-context") or "")
    servers: dict[str, str] = {}
    for item in doc.get("clusters") or []:
        if not isinstance(item, dict):
            continue
        name = clamp(item.get("name") or "")
        cluster = item.get("cluster") if isinstance(item.get("cluster"), dict) else {}
        server = clamp(cluster.get("server") or "")
        if name:
            servers[name] = server
    contexts: list[tuple[str, str, str]] = []
    for item in doc.get("contexts") or []:
        if not isinstance(item, dict):
            continue
        name = clamp(item.get("name") or "")
        ctx = item.get("context") if isinstance(item.get("context"), dict) else {}
        cluster = clamp(ctx.get("cluster") or "")
        namespace = clamp(ctx.get("namespace") or "default") or "default"
        if name:
            contexts.append((name, cluster, namespace))
        if len(contexts) >= MAX_CONTEXTS:
            break
    return current, contexts, servers


def readable_file(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def skip_name(name: str) -> bool:
    if name in SKIP_EXACT:
        return True
    return name.endswith(SKIP_SUFFIX)


def add_file(files: list[Path], seen: set[str], path: Path) -> None:
    if skip_name(path.name) or not readable_file(path):
        return
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    key = str(resolved)
    if key in seen:
        return
    seen.add(key)
    files.append(resolved)


def discover(home: Path, kubeconfig_env: str | None) -> tuple[Path, list[Path]]:
    kubehome = home / ".kube"
    files: list[Path] = []
    seen: set[str] = set()
    default: Path
    if kubeconfig_env:
        parts = [p for p in kubeconfig_env.split(":") if p]
        default = Path(parts[0]).expanduser() if parts else kubehome / "config"
        for part in parts:
            add_file(files, seen, Path(part).expanduser())
    else:
        default = kubehome / "config"
    try:
        default = default.resolve()
    except OSError:
        pass
    add_file(files, seen, default)
    try:
        entries = list(kubehome.iterdir())
    except OSError:
        entries = []
    for entry in entries:
        if entry.name == "cache":
            continue
        add_file(files, seen, entry)
    return default, files


def read_capped(path: Path) -> str | None:
    try:
        with path.open("rb") as handle:
            data = handle.read(MAX_FILE + 1)
    except OSError:
        return None
    if not data or len(data) > MAX_FILE:
        return None
    return data.decode("utf-8", errors="replace")


def emit(default: Path, files: list[Path]) -> None:
    sys.stdout.write("defaultfile=%s\n" % default)
    for path in files:
        text = read_capped(path)
        if text is None:
            continue
        try:
            doc = load_doc(text)
        except Exception:
            continue
        if not isinstance(doc, dict):
            continue
        current, contexts, servers = extract(doc)
        if not contexts:
            continue
        sys.stdout.write("file=%s\n" % path)
        sys.stdout.write("current=%s\n" % current)
        for name, cluster, namespace in contexts:
            sys.stdout.write("ctx=%s|%s|%s\n" % (name, cluster, namespace))
        for cluster_name, server in servers.items():
            sys.stdout.write("cluster=%s|%s\n" % (cluster_name, server))


def kubectl_missing() -> bool:
    paths = os.environ.get("PATH", "").split(":")
    for directory in paths:
        if not directory:
            continue
        candidate = Path(directory) / "kubectl"
        if os.access(candidate, os.X_OK):
            return False
    return True


def main() -> int:
    if kubectl_missing():
        sys.stdout.write("nokubectl=1\n")
    home = Path(os.environ.get("HOME") or str(Path.home()))
    default, files = discover(home, os.environ.get("KUBECONFIG"))
    emit(default, files)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
