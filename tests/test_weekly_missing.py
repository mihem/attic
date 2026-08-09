import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def shell_function(name):
    lines = (ROOT / "weekly-missing.sh").read_text().splitlines()
    start = lines.index(f"{name}() {{")
    for end in range(start + 1, len(lines)):
        if lines[end] == "}":
            return "\n".join(lines[start : end + 1])
    raise AssertionError(f"Could not find end of {name}")


class WeeklyMissingBlacklistTest(unittest.TestCase):
    def run_prepare(self, blacklist, state, date):
        script = shell_function("prepare_blacklist")
        env = os.environ.copy()
        env.update(
            {
                "BLACKLIST": str(blacklist),
                "BLACKLIST_DATE_FILE": str(state),
                "R_NIXPKGS_DATE": date,
            }
        )
        return subprocess.run(
            ["bash", "-c", f"{script}\nprepare_blacklist"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        ).stdout

    def test_automatic_date_is_resolved_before_blacklist_preparation(self):
        script = (ROOT / "weekly-missing.sh").read_text()

        self.assertIn("resolve_weekly_inputs\nprepare_blacklist", script)

    def test_first_run_associates_existing_blacklist_without_clearing(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            blacklist = directory / "blacklist.txt"
            state = directory / ".blacklist-date"
            blacklist.write_text("failed-package\n")

            self.run_prepare(blacklist, state, "2026-08-03")

            self.assertEqual("failed-package\n", blacklist.read_text())
            self.assertEqual("2026-08-03\n", state.read_text())

    def test_same_automatically_resolved_date_reuses_blacklist(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            blacklist = directory / "blacklist.txt"
            state = directory / ".blacklist-date"
            blacklist.write_text("failed-package\n")
            state.write_text("2026-08-03\n")

            output = self.run_prepare(blacklist, state, "2026-08-03")

            self.assertEqual("failed-package\n", blacklist.read_text())
            self.assertIn("Reusing blacklist", output)

    def test_new_automatically_resolved_date_clears_blacklist(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            blacklist = directory / "blacklist.txt"
            state = directory / ".blacklist-date"
            blacklist.write_text("failed-package\n")
            state.write_text("2026-08-03\n")

            output = self.run_prepare(blacklist, state, "2026-08-10")

            self.assertEqual("", blacklist.read_text())
            self.assertEqual("2026-08-10\n", state.read_text())
            self.assertIn("Cleared blacklist", output)


if __name__ == "__main__":
    unittest.main()
