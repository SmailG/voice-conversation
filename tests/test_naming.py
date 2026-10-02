import json
import os
import re
import subprocess
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OLD_NAME = re.compile(r"(?i:claude[-_]speak)|Claude ?Speak")  # not "Claude speaks"
# Files that must name the old install to take it over or explain the move.
MAY_NAME_OLD = {
    "README.md", "CONTRIBUTING.md", "hooks/tts.sh", "scripts/migrate.sh", "scripts/setup.sh",
    "tests/migrate.test.sh", "tests/test_naming.py",
}
# Claude Code refuses third-party plugin and marketplace names that pass as Anthropic's own.
RESERVED = re.compile(r"^(claude|anthropic|anthropics|cc-plugin)-|^(claude|anthropic|anthropics|claude-code|claude-mods)$")


def repo_files():
    """Tracked and new files, not ignored local state (e.g. .remember/)."""
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [rel for rel in out.splitlines() if os.path.isfile(os.path.join(ROOT, rel))]


class Naming(unittest.TestCase):
    def test_old_name_only_where_the_migration_needs_it(self):
        stale = []
        for rel in repo_files():
            if rel in MAY_NAME_OLD:
                continue
            try:
                with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
                    if OLD_NAME.search(f.read()):
                        stale.append(rel)
            except UnicodeDecodeError:
                continue  # binary (the voice sample)
        self.assertEqual(stale, [])

    def test_manifest_names_are_not_reserved(self):
        with open(os.path.join(ROOT, ".claude-plugin", "marketplace.json")) as f:
            market = json.load(f)
        with open(os.path.join(ROOT, ".claude-plugin", "plugin.json")) as f:
            plugin = json.load(f)
        names = [market["name"], plugin["name"]] + [p["name"] for p in market["plugins"]]
        self.assertEqual([n for n in names if RESERVED.search(n)], [])
        self.assertEqual(set(names), {"voice-conversation"})


if __name__ == "__main__":
    unittest.main()
