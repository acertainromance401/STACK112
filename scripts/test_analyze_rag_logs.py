import tempfile
from pathlib import Path
import unittest

from analyze_rag_logs import parse_log, timing_group


def fixture(status="passed", failures=0, failure_lines="", summaries=3):
    summary = f" Executed 1 test, with {failures} failures (0 unexpected) in 1.250 (1.260) seconds\n"
    return (
        "xcodebuild test -destination platform=iOS Simulator,id=test\n"
        "Test Suite 'Selected tests' started at 2026-11-02 19:00:00.000.\n"
        "Test Case '-[App.Tests testExample]' started.\n"
        f"{failure_lines}"
        f"Test Case '-[App.Tests testExample]' {status} (1.250 seconds).\n"
        + summary * summaries
        + "5.000 elapsed -- Testing started completed.\n"
        + ("** TEST SUCCEEDED **\n" if status == "passed" else "** TEST FAILED **\n")
    )


class LogParserTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.log"
            path.write_text(text, encoding="utf-8")
            return parse_log(path)

    def test_nested_summaries_do_not_triple_count(self):
        result = self.parse(fixture())
        self.assertEqual(len(result["cases"]), 1)
        self.assertEqual(result["run"]["tests"], 1)
        self.assertEqual(result["run"]["suite_elapsed_seconds"], 1.260)
        self.assertAlmostEqual(result["run"]["observer_minus_suite_seconds"], 3.740)
        self.assertEqual(len(result["source"]["sha256"]), 64)

    def test_assertions_are_not_failed_test_count(self):
        evidence = (
            "test.swift:1: error: -[App.Tests testExample] : XCTAssertEqual failed\n"
            "test.swift:2: error: -[App.Tests testExample] : XCTAssertNotNil failed\n"
        )
        result = self.parse(fixture("failed", 2, evidence))
        self.assertEqual(result["run"]["failed_tests"], 1)
        self.assertEqual(result["run"]["assertion_failures"], 2)
        self.assertEqual(len(result["failures"]), 2)
        self.assertTrue(all("test.swift" not in row["message"] for row in result["failures"]))

    def test_missing_and_contradictory_evidence_is_rejected(self):
        examples = [
            fixture().replace("** TEST SUCCEEDED **", ""),
            fixture().replace("started.\n", ""),
            fixture().replace("Executed 1 test", "Executed 2 tests"),
            fixture().replace("in 1.250", "in 9.000"),
            fixture().replace("platform=iOS Simulator", "platform=iOS"),
            fixture().replace("5.000 elapsed", "0.100 elapsed"),
            fixture().replace("** TEST SUCCEEDED **", "** TEST FAILED **"),
        ]
        for text in examples:
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    self.parse(text)

    def test_native_buffers_are_events_not_process_memory(self):
        native = (
            "load_tensors: CPU_Mapped model buffer size = 280.19 MiB\n"
            "load_tensors: CPU_Mapped model buffer size = 280.19 MiB\n"
            "sched_reserve: CPU compute buffer size = 12.76 MiB\n"
            "~llama_context: CPU compute buffer size is 12.7578 MiB\n"
            "check_double_bos_eos: Added a BOS token\n"
            "load_tensors: offloaded 0/13 layers to GPU\n"
        )
        result = self.parse(fixture().replace("5.000 elapsed", native + "5.000 elapsed"))
        self.assertEqual(len(result["buffers"]), 3)
        self.assertEqual(result["buffers"][0]["size_mib"], 280.19)
        self.assertEqual(len(result["diagnostics"]), 2)
        self.assertEqual(result["run"]["native_perf_lines"], 0)
        self.assertEqual(result["run"]["structured_measurement_lines"], 0)

    def test_native_and_hosted_cases_are_not_mock_latency(self):
        self.assertEqual(
            timing_group("testActualGGUFHybridRetrievalHasVerifiableModelIdentity"),
            "Native E5 checks",
        )
        self.assertEqual(
            timing_group("testRootSynchronizesInitialDataSameCountEditsAndDeletion"),
            "Hosted corpus synchronization",
        )
        self.assertEqual(timing_group("testExample"), "Other functional checks")

    def test_interleaved_native_progress_is_explicit_and_unambiguous(self):
        text = fixture().replace(
            "App.Tests testExample]' passed", "A.pp.Tests testExample]' passed"
        )
        result = self.parse(text)
        self.assertEqual(result["cases"][0]["class_name"], "App.Tests")
        self.assertEqual(result["cases"][0]["raw_end_class_name"], "A.pp.Tests")
        self.assertEqual(result["diagnostics"][0]["kind"], "xctest_interleaved_progress")
        with self.assertRaises(ValueError):
            self.parse(text.replace("A.pp.Tests", "Other.Tests"))

    def test_native_loader_prefix_preserves_test_line_evidence(self):
        text = fixture().replace(
            "Test Case '-[App.Tests testExample]' started.",
            "llama_model_loader: - kv 10: Test Case '-[App.Tests testExample]' started.",
        )
        result = self.parse(text)
        self.assertEqual(len(result["cases"]), 1)
        self.assertEqual(result["cases"][0]["start_line"], 3)
        self.assertEqual(result["diagnostics"][0]["kind"], "xctest_interleaved_prefix")


if __name__ == "__main__":
    unittest.main()
