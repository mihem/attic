import os
import unittest
from urllib.error import HTTPError
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

    def test_narinfo_reads_sizes(self):
        path = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package"

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                pass

            @staticmethod
            def read():
                return b"StorePath: ignored\nFileSize: 123\nNarSize: 456\n"

        with patch("attic_db.urlopen", return_value=Response()) as urlopen:
            result = attic_db.narinfo(path, "https://cache.nixos.org")

        self.assertEqual((path, 123, 456), result)
        self.assertEqual(
            "https://cache.nixos.org/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo",
            urlopen.call_args.args[0].full_url,
        )

    def test_narinfo_treats_404_as_missing(self):
        path = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package"
        error = HTTPError("url", 404, "missing", {}, None)

        with patch("attic_db.urlopen", side_effect=error):
            result = attic_db.narinfo(path, "https://cache.nixos.org")

        self.assertEqual((path, None, None), result)

    def test_parallel_upstream_check_sums_available_paths(self):
        paths = [
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a",
            "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b",
        ]

        def check(path, *_args):
            if path == paths[0]:
                return path, 100, 200
            return path, None, None

        with patch("attic_db.narinfo", side_effect=check):
            cached, file_bytes, nar_bytes = attic_db.upstream_cached_paths(
                paths, "https://cache.nixos.org", workers=2, progress_every=0
            )

        self.assertEqual({paths[0]}, cached)
        self.assertEqual(100, file_bytes)
        self.assertEqual(200, nar_bytes)


if __name__ == "__main__":
    unittest.main()
