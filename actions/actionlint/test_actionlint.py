"""Tests for install-actionlint.sh and run-actionlint.sh.

Run: python3 -B -m unittest discover -s actions/actionlint

Offline: stubs stand in for curl, uname, and actionlint. The real download and
the real actionlint output are exercised by the actionlint-action job in
.github/workflows/lint.yml.
"""

import hashlib
import io
import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
INSTALL = HERE / "install-actionlint.sh"
RUN = HERE / "run-actionlint.sh"
README = HERE.parent.parent / "README.md"

CURL_STUB = """#!/usr/bin/env bash
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$STUB_DIR/curl.log"
[ -z "${STUB_CURL_FAIL:-}" ] || exit 22
case "$url" in
  *shellcheck*) cp "$STUB_DIR/shellcheck.archive" "$out" ;;
  *) cp "$STUB_DIR/actionlint.archive" "$out" ;;
esac
"""

UNAME_STUB = """#!/usr/bin/env bash
case "$1" in
  -s) echo "${STUB_UNAME_S:-Linux}" ;;
  -m) echo "${STUB_UNAME_M:-x86_64}" ;;
esac
"""

ACTIONLINT_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "$STUB_DIR/actionlint.args"
cat "$STUB_DIR/findings"
exit "$STUB_EXIT"
"""


def write_executable(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def tar_bytes(mode, name, content):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode=mode) as archive:
        info = tarfile.TarInfo(name)
        info.size = len(content)
        info.mode = 0o755
        archive.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


class StubbedTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.stubs}{os.pathsep}{os.environ['PATH']}",
            "STUB_DIR": str(self.stubs),
        }


@unittest.skipUnless(shutil.which("sha256sum"), "sha256sum is not installed")
class InstallTest(StubbedTest):
    def setUp(self):
        super().setUp()
        write_executable(self.stubs / "curl", CURL_STUB)
        write_executable(self.stubs / "uname", UNAME_STUB)
        self.dest = self.tmp / "dest"
        self.actionlint_archive = tar_bytes("w:gz", "actionlint", b"#!/bin/sh\necho stub\n")
        (self.stubs / "actionlint.archive").write_bytes(self.actionlint_archive)
        (self.stubs / "shellcheck.archive").write_bytes(b"not the pinned shellcheck")

    def install(self, version="", sha256="", **env):
        return subprocess.run(
            ["bash", str(INSTALL), str(self.dest)],
            env={
                **self.env,
                "ACTIONLINT_VERSION": version,
                "ACTIONLINT_SHA256": sha256,
                **env,
            },
            capture_output=True,
            text=True,
            check=False,
        )

    def downloads(self):
        log = self.stubs / "curl.log"
        return log.read_text().splitlines() if log.exists() else []

    def assert_nothing_installed(self):
        self.assertFalse((self.dest / "actionlint").exists())
        self.assertFalse((self.dest / "shellcheck").exists())

    def test_unknown_version_fails_before_any_download(self):
        result = self.install(version="0.0.1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=actionlint::actionlint 0.0.1 has no known checksum", result.stderr)
        self.assertIn("actionlint-sha256", result.stderr)
        self.assertIn("gh release view v0.0.1 -R rhysd/actionlint", result.stderr)
        self.assertEqual(self.downloads(), [])
        self.assert_nothing_installed()

    def test_malformed_version_fails_before_any_download(self):
        for version in ("v1.7.12", "1.7", "1.7.12/../../evil", "1.7.12; true", "latest"):
            with self.subTest(version=version):
                result = self.install(version=version)
                self.assertEqual(result.returncode, 1)
                self.assertIn("is not a release number", result.stderr)
                self.assertEqual(self.downloads(), [])

    def test_malformed_checksum_fails_before_any_download(self):
        for sha256 in ("abc", "g" * 64, "a" * 63, "a" * 65):
            with self.subTest(sha256=sha256):
                result = self.install(version="0.0.1", sha256=sha256)
                self.assertEqual(result.returncode, 1)
                self.assertIn("is not 64 hexadecimal characters", result.stderr)
                self.assertEqual(self.downloads(), [])

    def test_checksum_disagreeing_with_the_pin_fails_before_any_download(self):
        result = self.install(version="1.7.12", sha256="a" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn("disagrees with", result.stderr)
        self.assertEqual(self.downloads(), [])

    def test_pinned_version_rejects_an_archive_that_is_not_the_release(self):
        result = self.install()
        self.assertEqual(result.returncode, 1)
        self.assertIn("the download is not the pinned release", result.stderr)
        self.assert_nothing_installed()

    def test_supplied_checksum_rejects_an_archive_that_does_not_match(self):
        result = self.install(version="0.0.1", sha256="a" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn("the download is not the pinned release", result.stderr)
        self.assertEqual(len(self.downloads()), 1)
        self.assert_nothing_installed()

    def test_shellcheck_is_verified_even_when_actionlint_matches(self):
        digest = hashlib.sha256(self.actionlint_archive).hexdigest()
        result = self.install(version="0.0.1", sha256=digest.upper())
        self.assertEqual(result.returncode, 1)
        self.assertIn("shellcheck-v0.11.0.linux.x86_64.tar.xz has sha256", result.stderr)
        self.assert_nothing_installed()

    def test_failed_download_names_the_url(self):
        result = self.install(STUB_CURL_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not download https://github.com/rhysd/actionlint/", result.stderr)

    def test_downloads_only_from_upstream(self):
        self.install()
        self.assertEqual(
            self.downloads(),
            ["https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz"],
        )

    def test_arm_runner_selects_the_arm_archive(self):
        self.install(STUB_UNAME_M="aarch64")
        self.assertEqual(
            self.downloads(),
            ["https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz"],
        )

    def test_unsupported_platform_fails_before_any_download(self):
        result = self.install(STUB_UNAME_S="Darwin", STUB_UNAME_M="arm64")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not Darwin-arm64", result.stderr)
        self.assertEqual(self.downloads(), [])


class RunTest(StubbedTest):
    def run_action(self, findings="", exit_code=0):
        write_executable(self.stubs / "actionlint", ACTIONLINT_STUB)
        (self.stubs / "findings").write_text(findings)
        return subprocess.run(
            ["bash", str(RUN), str(self.stubs)],
            env={**self.env, "STUB_EXIT": str(exit_code)},
            capture_output=True,
            text=True,
            check=False,
        )

    @staticmethod
    def finding(kind, message, file=".github/workflows/a.yml", line=6, column=9):
        return f"{file}\t{line}\t{column}\t{kind}\t{message}\n"

    @staticmethod
    def shellcheck(severity):
        return f"shellcheck reported issue in this script: SC2086:{severity}:1:6: Double quote"

    def test_clean_run_passes(self):
        result = self.run_action()
        self.assertEqual(result.returncode, 0)
        self.assertIn("actionlint: no findings", result.stdout)
        self.assertNotIn("::", result.stdout)

    def test_passes_the_pinned_shellcheck_and_disables_pyflakes(self):
        self.run_action()
        args = (self.stubs / "actionlint.args").read_text().splitlines()
        self.assertIn(f"-shellcheck={self.stubs}/shellcheck", args)
        self.assertIn("-pyflakes=", args)

    def test_severity_gate(self):
        cases = {
            "warning": ("warning", 0),
            "info": ("notice", 0),
            "style": ("error", 1),
            "error": ("error", 1),
        }
        for severity, (level, code) in cases.items():
            with self.subTest(severity=severity):
                result = self.run_action(self.finding("shellcheck", self.shellcheck(severity)), 1)
                self.assertEqual(result.returncode, code)
                self.assertTrue(result.stdout.startswith(f"::{level} file=.github/workflows/a.yml,line=6,col=9,"))

    def test_finding_outside_shellcheck_fails_whatever_it_says(self):
        result = self.run_action(self.finding("expression", self.shellcheck("info")), 1)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stdout.startswith("::error "))

    def test_shellcheck_line_it_cannot_read_fails(self):
        result = self.run_action(self.finding("shellcheck", "shellcheck said something new"), 1)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stdout.startswith("::error "))

    def test_every_finding_annotates_and_one_error_fails_the_run(self):
        findings = (
            self.finding("shellcheck", self.shellcheck("info"), line=1)
            + self.finding("expression", "property is not defined", line=2)
            + self.finding("shellcheck", self.shellcheck("warning"), line=3)
        )
        result = self.run_action(findings, 1)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            [line.split(" ")[0] for line in result.stdout.splitlines() if line.startswith("::")],
            ["::notice", "::error", "::warning"],
        )
        self.assertIn("actionlint: 1 failing, 2 below the gate", result.stdout)

    def test_fatal_exit_fails_with_actionlint_status(self):
        for code in (2, 3):
            with self.subTest(code=code):
                result = self.run_action(exit_code=code)
                self.assertEqual(result.returncode, code)
                self.assertIn(f"exited {code}", result.stdout)

    def test_findings_it_cannot_read_fail(self):
        result = self.run_action("", 1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not read", result.stdout)

    def test_values_are_escaped_for_the_command_syntax(self):
        result = self.run_action(
            self.finding("expression", "100% of ::set-output:: name=x", file=".github/workflows/a,b:c.yml"), 1
        )
        self.assertIn(
            "::error file=.github/workflows/a%2Cb%3Ac.yml,line=6,col=9,title=actionlint::"
            "100%25 of ::set-output:: name=x [expression]\n",
            result.stdout,
        )

    def test_a_finding_cannot_start_its_own_command_line(self):
        result = self.run_action(
            self.finding("expression", "first\r::add-mask::secret"), 1
        )
        commands = [line for line in re.split(r"[\r\n]", result.stdout) if line.startswith("::")]
        self.assertEqual(len(commands), 1)
        self.assertIn("first%0D::add-mask::secret", commands[0])


class TemplateTest(StubbedTest):
    """The real actionlint, when installed, reads the format string as written."""

    @unittest.skipUnless(
        shutil.which("actionlint") and shutil.which("shellcheck"),
        "actionlint or shellcheck is not installed",
    )
    def test_real_findings_become_annotations(self):
        (self.stubs / "actionlint").symlink_to(shutil.which("actionlint"))
        (self.stubs / "shellcheck").symlink_to(shutil.which("shellcheck"))
        workflows = self.tmp / "project" / ".github" / "workflows"
        workflows.mkdir(parents=True)
        (self.tmp / "project" / ".git").mkdir()
        (workflows / "a.yml").write_text(
            "on: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n"
            "      - run: echo $HOME\n      - run: echo ${{ matrix.nope }}\n"
        )
        result = subprocess.run(
            ["bash", str(RUN), str(self.stubs)],
            cwd=self.tmp / "project",
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertRegex(result.stdout, r"::notice file=\.github/workflows/a\.yml,line=6,col=\d+,title=actionlint::shellcheck reported issue in this script: SC2086:info:")
        self.assertRegex(result.stdout, r"::error file=\.github/workflows/a\.yml,line=7,col=\d+,title=actionlint::property \"nope\" is not defined")
        self.assertIn("actionlint: 1 failing, 1 below the gate", result.stdout)


class DocumentationTest(unittest.TestCase):
    def test_readme_names_the_pinned_default_version(self):
        default = re.search(r"^default_version=(\S+)$", INSTALL.read_text(), re.M).group(1)
        self.assertRegex(
            README.read_text(),
            rf"\| `actionlint-version` +\| string +\| empty \(`{re.escape(default)}`\) +\|",
        )


if __name__ == "__main__":
    unittest.main()
