import os
import unittest
from unittest.mock import patch

import attic_db


class AtticDatabaseTest(unittest.TestCase):
    def test_backend(self):
        self.assertEqual("sqlite", attic_db.backend("/tmp/attic.db"))
        self.assertEqual("sqlite", attic_db.backend("sqlite:///tmp/attic.db?mode=ro"))
        self.assertEqual(
            "postgresql",
            attic_db.backend("postgresql:///attic?host=/run/postgresql"),
        )

    def test_rejects_unknown_backend(self):
        with self.assertRaisesRegex(ValueError, "Unsupported database"):
            attic_db.backend("mysql:///attic")

    def test_postgresql_command_uses_service_account(self):
        command = attic_db.command("postgresql:///attic", "select 1")
        self.assertEqual(["sudo", "-u", "attic"], command[:3])
        self.assertIn("psql", command)
        self.assertIn("ON_ERROR_STOP=1", command)

    def test_sqlite_url_command_uses_file_path(self):
        with patch.dict(os.environ, {"ATTIC_DB_NO_SUDO": "1"}):
            command = attic_db.command("sqlite:///tmp/attic.db?mode=ro", "select 1")
        self.assertEqual("sqlite3", command[0])
        self.assertIn("/tmp/attic.db", command)

    def test_cached_hashes(self):
        with patch("attic_db.query", return_value="hash-a\nhash-b\n") as query:
            hashes = attic_db.cached_hashes("/tmp/attic.db", "r-'packages")

        self.assertEqual({"hash-a", "hash-b"}, hashes)
        self.assertIn("r-''packages", query.call_args.args[1])


if __name__ == "__main__":
    unittest.main()
