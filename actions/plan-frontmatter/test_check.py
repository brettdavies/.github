"""Tests for check.py. Run: python3 -B -m unittest discover -s actions/plan-frontmatter

Requires mikefarah yq v4 on PATH or named by YQ.
"""

import datetime
import importlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Set before check loads, so a test run leaves no __pycache__ beside it.
sys.dont_write_bytecode = True
check = importlib.import_module("check")

CHECK = Path(__file__).resolve().parent / "check.py"
SHA = "0123456789abcdef0123456789abcdef01234567"

CONVENTION = {
    "proposed": (),
    "active": (),
    "blocked": ("blocked_on",),
    "merged": ("prs", "completed"),
    "released": ("prs", "completed", "released_in"),
    "done": ("completed",),
    "superseded": ("superseded_by",),
    "dropped": ("dropped_reason",),
}

VALID = {
    "proposed": "status: proposed\n",
    "active": "status: active\n",
    "blocked": "status: blocked\nblocked_on: brettdavies/agentnative-site#40 merging\n",
    "merged": 'status: merged\nprs: ["#149"]\ncompleted: 2026-10-26\n',
    "released": 'status: released\nprs: ["#149"]\ncompleted: 2026-10-26\nreleased_in: v0.7.0\n',
    "done": "status: done\ncompleted: 2026-10-26\n",
    "superseded": "status: superseded\nsuperseded_by: docs/plans/2026-10-26-001-feat-next-plan.md\n",
    "dropped": "status: dropped\ndropped_reason: the site owns this check\n",
}


class Case(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def problems(self, frontmatter, body="# Plan\n"):
        text = body if frontmatter is None else f"---\n{frontmatter}---\n{body}"
        return check.check_file(str(self.write("plan.md", text)))

    def messages(self, frontmatter):
        return [problem.message for problem in self.problems(frontmatter)]

    def assertValid(self, frontmatter):
        self.assertEqual(self.messages(frontmatter), [])

    def assertProblem(self, frontmatter, *fragments):
        messages = self.messages(frontmatter)
        self.assertTrue(
            any(
                all(fragment in message for fragment in fragments)
                for message in messages
            ),
            f"no message holds {fragments}: {messages}",
        )
        return messages


class StatusTests(Case):
    def test_statuses_and_required_keys_match_the_convention(self):
        self.assertEqual(dict(check.REQUIRED), CONVENTION)
        self.assertEqual(set(VALID), set(CONVENTION))

    def test_every_status_with_its_keys_is_valid(self):
        for status, frontmatter in VALID.items():
            with self.subTest(status=status):
                self.assertValid(frontmatter)

    def test_every_status_missing_a_companion_names_it(self):
        for status, keys in CONVENTION.items():
            for key in keys:
                with self.subTest(status=status, key=key):
                    lines = [
                        line
                        for line in VALID[status].splitlines(True)
                        if not line.startswith(key + ":")
                    ]
                    self.assertProblem(
                        "".join(lines), f"status: {status} needs", f"{key}:", "add"
                    )

    def test_merged_missing_both_keys_lists_both_with_examples(self):
        today = datetime.date.today().isoformat()
        messages = self.assertProblem(
            "status: merged\n", "status: merged needs prs: and completed:"
        )
        self.assertIn(f'add prs: ["#123"] and completed: {today}', messages[0])

    def test_released_missing_all_keys_lists_three(self):
        self.assertProblem(
            "status: released\n", "needs prs:, completed:, and released_in:"
        )

    def test_missing_status(self):
        self.assertProblem(
            "title: a plan\n", "status: is missing", "proposed, active, blocked"
        )

    def test_unknown_status(self):
        for value in ("complete", "Merged", "shipped"):
            with self.subTest(value=value):
                self.assertProblem(
                    f"status: {value}\n", f'status: "{value}" is not a known status'
                )

    def test_non_string_status(self):
        self.assertProblem("status: [merged]\n", "is not a known status")

    def test_active_and_blocked_accept_prs(self):
        self.assertValid('status: active\nprs: ["#1", "brettdavies/agentnative#12"]\n')
        self.assertValid('status: blocked\nblocked_on: upstream fix\nprs: ["#3"]\n')
        self.assertValid('status: proposed\nprs: ["#4"]\n')

    def test_prs_on_done_superseded_and_dropped_are_allowed(self):
        self.assertValid(VALID["done"] + 'prs: ["#5"]\n')
        self.assertValid(VALID["superseded"] + 'prs: ["#6"]\n')
        self.assertValid(VALID["dropped"] + 'prs: ["#7"]\n')


class MisplacedKeyTests(Case):
    def test_keys_owned_by_another_status(self):
        cases = {
            "completed": (
                "status: active\ncompleted: 2026-10-26\n",
                "merged, released, or done",
            ),
            "released_in": (VALID["merged"] + "released_in: v1.0.0\n", "released"),
            "superseded_by": (
                VALID["dropped"] + "superseded_by: docs/plans/x.md\n",
                "superseded",
            ),
            "dropped_reason": ("status: proposed\ndropped_reason: no\n", "dropped"),
            "blocked_on": ("status: active\nblocked_on: review\n", "blocked"),
        }
        for key, (frontmatter, owners) in cases.items():
            with self.subTest(key=key):
                self.assertProblem(
                    frontmatter, f"{key}: applies only to status {owners}", "remove it"
                )

    def test_misplaced_key_reports_its_own_line(self):
        problems = self.problems("status: active\ntitle: x\ncompleted: 2026-10-26\n")
        self.assertEqual(
            [(problem.line, problem.message.split(":")[0]) for problem in problems],
            [(4, "completed")],
        )

    def test_missing_companion_reports_the_status_line(self):
        problems = self.problems("title: x\nstatus: done\n")
        self.assertEqual([problem.line for problem in problems], [3])


class PrsFormatTests(Case):
    def test_valid_refs(self):
        for ref in ("#1", "#149", "brettdavies/agentnative-cli#12", "a.b_c-d/e.f#3"):
            with self.subTest(ref=ref):
                self.assertValid(f'status: active\nprs: ["{ref}"]\n')

    def test_invalid_refs(self):
        for ref in (
            "PR-149",
            "#",
            "149",
            "owner#1",
            "owner/repo/x#1",
            "#12a",
            "https://github.com/o/r/pull/1",
        ):
            with self.subTest(ref=ref):
                self.assertProblem(
                    f'status: active\nprs: ["{ref}"]\n', "is not #N or owner/repo#N"
                )

    def test_each_bad_entry_is_its_own_problem(self):
        messages = self.messages('status: active\nprs: ["#1", "x", "y"]\n')
        self.assertEqual(len(messages), 2)

    def test_number_entry_says_quote_it(self):
        self.assertProblem(
            "status: active\nprs: [149]\n",
            "149 is not a string",
            'quote it, as in "#149"',
        )

    def test_scalar_is_not_a_list(self):
        self.assertProblem(
            'status: active\nprs: "#149"\n', "is not a list", 'prs: ["#123"]'
        )

    def test_empty_list(self):
        self.assertProblem("status: active\nprs: []\n", "empty list", "unquoted #")

    def test_unquoted_ref_in_flow_list_says_quote(self):
        for frontmatter in (
            "status: merged\nprs: [#149]\ncompleted: 2026-10-26\n",
            "status: active\nprs: [ #149 ]\n",
        ):
            with self.subTest(frontmatter=frontmatter):
                self.assertProblem(
                    frontmatter, "not valid YAML", "quote each PR ref", 'prs: ["#123"]'
                )
                self.assertEqual(
                    [problem.line for problem in self.problems(frontmatter)], [3]
                )

    def test_unquoted_ref_as_scalar_reads_as_no_value(self):
        self.assertProblem(
            "status: active\nprs: #149\n", "prs: has no value", "unquoted #"
        )

    def test_unquoted_ref_in_block_list_reads_as_empty_entry(self):
        self.assertProblem(
            "status: active\nprs:\n  - #149\n", "empty entry", "unquoted #"
        )

    def test_quoted_block_list_is_valid(self):
        self.assertValid(
            'status: merged\nprs:\n  - "#149"\n  - "brettdavies/agentnative#3"\ncompleted: 2026-10-26\n'
        )


class CompletedFormatTests(Case):
    def test_unquoted_and_quoted_dates(self):
        self.assertValid("status: done\ncompleted: 2026-10-26\n")
        self.assertValid('status: done\ncompleted: "2026-10-26"\n')

    def test_not_a_real_date(self):
        self.assertProblem(
            "status: done\ncompleted: 2026-02-30\n", "is not a real date"
        )

    def test_wrong_shapes(self):
        for value in (
            "26-10-2026",
            "2026-10-26T10:00:00Z",
            "2026/10/26",
            "20261026",
            "yesterday",
        ):
            with self.subTest(value=value):
                self.assertProblem(
                    f"status: done\ncompleted: {value}\n", "is not a YYYY-MM-DD date"
                )

    def test_no_value(self):
        self.assertProblem("status: done\ncompleted:\n", "completed: has no value")


class ReleasedInFormatTests(Case):
    def released(self, value):
        return VALID["merged"].replace("merged", "released") + f"released_in: {value}\n"

    def test_valid_forms(self):
        for value in (
            "v0.7.0",
            "v1.2.3-rc.1",
            "v1.2.3+build.5",
            "v1.2.3-rc.1+b7",
            '"#88"',
            SHA,
            SHA.upper(),
        ):
            with self.subTest(value=value):
                self.assertValid(self.released(value))

    def test_invalid_forms(self):
        for value in ("1.2.3", "v1.2", "release-1", SHA[:39], SHA + "0", '"#88x"'):
            with self.subTest(value=value):
                self.assertProblem(
                    self.released(value),
                    "is not a release tag (vX.Y.Z), a release PR (#N), or a commit SHA",
                )

    def test_unquoted_pr_reads_as_no_value(self):
        self.assertProblem(
            self.released("#88"), "released_in: has no value", "unquoted #"
        )

    def test_number_says_quote_it(self):
        self.assertProblem(self.released("12"), "is not a string; quote it")


class TextFieldTests(Case):
    def test_empty_values(self):
        for status, key in (
            ("blocked", "blocked_on"),
            ("superseded", "superseded_by"),
            ("dropped", "dropped_reason"),
        ):
            for value in ("", '""', '"   "', "42", "[a]"):
                with self.subTest(key=key, value=value):
                    self.assertProblem(
                        f"status: {status}\n{key}: {value}\n", f"{key}: must name"
                    )

    def test_superseded_by_cross_repo_path(self):
        self.assertValid(
            "status: superseded\nsuperseded_by: brettdavies/agentnative-site:docs/plans/x.md\n"
        )


class DocumentTests(Case):
    def test_unknown_keys_are_ignored(self):
        self.assertValid(
            VALID["merged"]
            + 'title: "feat: a plan"\ntype: feat\ndate: 2026-10-01\ntopic: scoring\n'
            + "origin: docs/brainstorms/x.md\ndeepened: 2026-10-02\n"
            + "artifact_contract:\n  inputs: [a, b]\n  outputs: {c: d}\nartifact_readiness: draft\n"
        )

    def test_no_frontmatter(self):
        self.assertProblem(None, "no frontmatter", "start the file with a --- line")

    def test_frontmatter_after_line_one_is_not_frontmatter(self):
        problems = check.check_file(
            str(self.write("p.md", "# Title\n\n---\nstatus: active\n---\n"))
        )
        self.assertEqual(
            [(p.line, "no frontmatter" in p.message) for p in problems], [(1, True)]
        )

    def test_empty_file(self):
        problems = check.check_file(str(self.write("empty.md", "")))
        self.assertIn("no frontmatter", problems[0].message)

    def test_unclosed_frontmatter(self):
        problems = check.check_file(
            str(self.write("p.md", "---\nstatus: active\n# Plan\n"))
        )
        self.assertIn("never closes", problems[0].message)

    def test_bad_yaml_reports_the_file_line(self):
        problems = self.problems('status: active\ntitle: "unterminated\nother: x\n')
        self.assertEqual(len(problems), 1)
        self.assertIn("not valid YAML", problems[0].message)
        self.assertNotIn("quote each PR ref", problems[0].message)
        self.assertEqual(problems[0].line, 3)

    def test_empty_frontmatter_needs_status(self):
        self.assertProblem("", "status: is missing")

    def test_non_mapping_frontmatter(self):
        self.assertProblem("- status\n- active\n", "must be key: value lines")

    def test_duplicate_key(self):
        problems = self.problems(
            "status: active\ntitle: x\nstatus: done\ncompleted: 2026-10-26\n"
        )
        duplicate = [
            problem
            for problem in problems
            if "appears more than once" in problem.message
        ]
        self.assertEqual(
            [(problem.line, problem.message.split(":")[0]) for problem in duplicate],
            [(4, "status")],
        )

    def test_crlf_and_bom(self):
        path = self.write("p.md", "")
        path.write_bytes(b"\xef\xbb\xbf---\r\nstatus: active\r\n---\r\n# Plan\r\n")
        self.assertEqual(check.check_file(str(path)), [])


class AnnotationTests(unittest.TestCase):
    def test_format(self):
        problem = check.Problem("docs/plans/a,b:c.md", 3, "50% done\nnext")
        self.assertEqual(
            check.annotation(problem),
            "::error file=docs/plans/a%2Cb%3Ac.md,line=3,title=plan frontmatter::50%25 done%0Anext",
        )

    def test_without_file(self):
        self.assertEqual(
            check.annotation(check.Problem(None, None, "x")),
            "::error title=plan frontmatter::x",
        )


class CliTests(Case):
    def run_check(self, *arguments, env=None):
        return subprocess.run(
            [sys.executable, "-B", str(CHECK), *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
            env={**os.environ, **(env or {})},
            check=False,
        )

    def test_valid_plans_exit_zero(self):
        self.write("docs/plans/a.md", f"---\n{VALID['active']}---\n")
        self.write("docs/plans/b.md", f"---\n{VALID['done']}---\n")
        result = self.run_check("docs/plans/*.md")
        self.assertEqual(
            (result.returncode, result.stdout),
            (0, "plan frontmatter: 2 file(s) valid\n"),
        )

    def test_problems_exit_one_with_annotations_and_summary(self):
        self.write("docs/plans/a.md", f"---\n{VALID['active']}---\n")
        self.write("docs/plans/b.md", "---\ntitle: x\nstatus: merged\n---\n")
        result = self.run_check("docs/plans/*.md")
        self.assertEqual(result.returncode, 1)
        lines = result.stdout.splitlines()
        self.assertTrue(
            lines[0].startswith(
                "::error file=docs/plans/b.md,line=3,title=plan frontmatter::status: merged needs"
            )
        )
        self.assertTrue(
            lines[-1].startswith("plan frontmatter: 1 problem(s) in 1 of 2 file(s)")
        )

    def test_zero_matches_exit_one(self):
        self.write("docs/plans/a.md", f"---\n{VALID['active']}---\n")
        result = self.run_check("docs/plans/*.md docs/plan/*.md")
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            '::error title=plan frontmatter::no file matches the glob "docs/plan/*.md"',
            result.stdout,
        )

    def test_no_patterns_exit_one(self):
        result = self.run_check("  ")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no glob patterns given", result.stdout)

    def test_recursive_glob_and_directories_skipped(self):
        self.write("docs/plans/a.md", f"---\n{VALID['active']}---\n")
        self.write("docs/plans/archive/old.md", "no frontmatter\n")
        (self.root / "docs/plans/dir.md").mkdir()
        result = self.run_check("docs/plans/**/*.md")
        self.assertEqual(result.returncode, 1)
        self.assertIn("file=docs/plans/archive/old.md,line=1", result.stdout)
        self.assertIn("in 1 of 2 file(s)", result.stdout)

    def test_missing_yq_exit_two(self):
        self.write("docs/plans/a.md", f"---\n{VALID['active']}---\n")
        result = self.run_check(
            "docs/plans/*.md", env={"YQ": str(self.root / "no-such-yq")}
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("yq could not run", result.stdout)


if __name__ == "__main__":
    unittest.main()
