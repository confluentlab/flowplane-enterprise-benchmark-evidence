#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if not __debug__:
    raise RuntimeError("Evidence validation must not run with Python assertions disabled.")
APPROVED_STATUSES = {
    "QUALIFIED",
    "MEASURED",
    "MEASURED_NOT_QUALIFIED",
    "CONTRACT_VERIFIED",
    "SOURCE_INSPECTED",
    "LIVE_LOCAL_VERIFIED",
    "INCOMPLETE",
    "PRESERVED_FAILURE",
    "NOT_TESTED",
    "VENDOR_CERTIFIED",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(relative: str) -> list[dict[str, str]]:
    with (ROOT / relative).open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def check_hashes() -> None:
    manifest_path = ROOT / "evidence/checksums.sha256"
    entries: dict[str, str] = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        expected, relative = line.split("  ", 1)
        assert relative not in entries, f"duplicate checksum entry: {relative}"
        path = ROOT / relative
        assert path.is_file(), f"checksum path missing: {relative}"
        assert digest(path) == expected, f"checksum mismatch: {relative}"
        entries[relative] = expected
    inventory = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    expected_files = {
        relative.replace("\\", "/") for relative in inventory
        if (ROOT / relative).is_file()
        and relative.replace("\\", "/") != "evidence/checksums.sha256"
        and not (relative.replace("\\", "/").startswith("release/") and relative.replace("\\", "/").endswith("/checksums.sha256"))
    }
    current_tag = json.loads((ROOT / "evidence/manifest.json").read_text(encoding="utf-8"))["releaseTag"]
    for release_checksums in [ROOT / "release" / current_tag / "checksums.sha256"]:
        release_root = release_checksums.parent
        release_entries: set[str] = set()
        for line in release_checksums.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            expected, relative = line.split("  ", 1)
            assert relative not in release_entries, f"duplicate release checksum entry: {release_root / relative}"
            target = release_root / relative
            assert target.is_file(), f"release checksum path missing: {target}"
            assert digest(target) == expected, f"release checksum mismatch: {target}"
            release_entries.add(relative)
        expected_release_entries = {path.name for path in release_root.iterdir() if path.is_file() and path != release_checksums}
        assert release_entries == expected_release_entries, f"release checksum inventory mismatch: {release_root}"
    assert set(entries) == expected_files, f"checksum inventory mismatch: missing={sorted(expected_files-set(entries))}, stale={sorted(set(entries)-expected_files)}"


def check_release_archive() -> None:
    manifest = json.loads((ROOT / "evidence/manifest.json").read_text(encoding="utf-8"))
    release_root = ROOT / "release" / manifest["releaseTag"]
    assert (release_root / "evidence-manifest.json").read_bytes() == (ROOT / "evidence/manifest.json").read_bytes(), "release manifest copy is stale"
    expected = {
        path.relative_to(ROOT / "evidence").as_posix(): path
        for evidence_root in (ROOT / "evidence/integration-proofs", ROOT / "evidence/trigger-proofs")
        for path in evidence_root.rglob("*") if path.is_file()
    }
    with zipfile.ZipFile(release_root / "raw-evidence.zip") as archive:
        file_entries = [name for name in archive.namelist() if not name.endswith("/")]
        archived = {name.replace("\\", "/"): name for name in file_entries}
        assert len(file_entries) == len(archived), "raw evidence archive contains duplicate file names"
        assert set(archived) == set(expected), "raw evidence archive inventory differs from source tree"
        for relative, source in expected.items():
            assert hashlib.sha256(archive.read(archived[relative])).hexdigest() == digest(source), f"stale raw archive entry: {relative}"


def check_claims() -> None:
    claims = rows("evidence/claims-matrix.csv")
    assert claims, "claims matrix is empty"
    for claim in claims:
        assert claim["claim_id"], "public claim lacks claim ID"
        assert claim["evidence_id"], f"{claim['claim_id']} lacks supporting evidence ID"
        assert claim["public_claim"], f"{claim['claim_id']} lacks public claim text"
        assert claim["status"] in APPROVED_STATUSES, f"{claim['claim_id']} uses invalid status {claim['status']}"
        evidence = ROOT / claim["evidence_path"]
        assert evidence.is_file(), f"{claim['claim_id']} evidence path missing: {claim['evidence_path']}"


def check_manifest() -> None:
    manifest = json.loads((ROOT / "evidence/manifest.json").read_text(encoding="utf-8"))
    assert manifest["releaseTag"].startswith("evidence-"), "release manifest points to a mutable ref"
    assert manifest["repositoryCommit"] == f"resolved-by-release-tag:{manifest['releaseTag']}"
    for key in ("statusVocabulary", "claimsMatrix", "checksums"):
        assert (ROOT / manifest[key]).is_file(), f"manifest path missing: {manifest[key]}"
    for asset in manifest["releaseAssets"]:
        assert (ROOT / asset).is_file(), f"release asset missing: {asset}"
    ids: set[str] = set()
    for run in manifest["runs"]:
        assert run["id"] not in ids, f"duplicate evidence run ID: {run['id']}"
        ids.add(run["id"])
        assert run["status"] in APPROVED_STATUSES, f"run {run['id']} uses invalid status"
        for key in ("summary", "rawResults", "environment", "methodology"):
            assert run.get(key), f"run {run['id']} lacks {key}"
            assert (ROOT / run[key]).is_file(), f"run {run['id']} path missing: {run[key]}"
        for chart in run.get("charts", []):
            assert (ROOT / chart).is_file(), f"run {run['id']} chart missing: {chart}"
        assert digest(ROOT / run["rawResults"]) == run["checksum"], f"run checksum mismatch: {run['id']}"
    assert (ROOT / f"release/{manifest['releaseTag']}/benchmark-summary.md").is_file(), "release summary missing"


def check_repeatability() -> None:
    result = json.loads((ROOT / "evidence/core-engine/qualification-results.json").read_text())
    gates = result["gates"]
    assert result["status"] == "MEASURED_NOT_QUALIFIED"
    assert len(gates) == 12 and sum(gate["passed"] for gate in gates) == 9
    misses = {gate["name"] for gate in gates if not gate["passed"]}
    assert misses == {"success.B.meanSpread", "errors.A.meanSpread", "errors.B.meanSpread"}
    assert all(gate["passed"] == (gate["observed"] <= gate["maximum"]) for gate in gates)
    gate_values = {gate["name"]: gate["observed"] for gate in gates}
    for workload in ("success", "errors"):
        for group in ("A", "B"):
            launches = result["launchMeansUsPerOp"][workload][group]
            assert len(launches) == 3 and all(value > 0 for value in launches)
            median = sorted(launches)[1]
            spread = (max(launches) - min(launches)) / median
            assert abs(spread - gate_values[f"{workload}.{group}.meanSpread"]) < 1e-12


def check_soak() -> None:
    producer = json.loads((ROOT / "evidence/kafka-soak/producer-results.json").read_text())
    consumer = json.loads((ROOT / "evidence/kafka-soak/consumer-results.json").read_text())
    produced = producer["recordsProducedToRaw"]
    consumed = consumer["recordsConsumedFromRaw"]
    output = consumer["recordsProducedToOutput"]
    failed = consumer["recordsFailed"]
    assert produced == 1_080_001
    assert consumed == produced
    assert output + failed == produced, "soak accounting mismatch"
    assert failed == 10_800
    assert consumer["rawConsumerLagEnd"] == 0
    assert producer["inputMode"] == "generated-synthetic"
    assert producer["targetRatePerSecond"] == 600
    assert producer["inputBytes"] == 110_591_022_399
    assert abs(producer["producerRecordsPerSec"] - 599.8759539547755) < 1e-12
    assert abs(consumer["recordsPerSecEndToEnd"] - 532.1447534405139) < 1e-12
    assert abs(consumer["drainTimeSeconds"] - 2029.5248483) < 1e-9


def check_parity() -> None:
    parity = rows("evidence/runtime-parity/parity-matrix.csv")
    assert len(parity) == 5
    for row in parity:
        assert row["status"] == "CONTRACT_VERIFIED"
        assert row["expected_output_sha256"] == row["actual_output_sha256"]
        assert row["expected_error"] == row["actual_error"] == "INVALID_PAYLOAD"
        assert row["expected_stage"] == row["actual_stage"] == "INPUT_PARSE"


def check_scaling_and_charts() -> None:
    scaling = rows("evidence/payload-scaling/results.csv")
    assert [int(row["size_mib"]) for row in scaling] == [1, 2, 4, 8, 16, 32, 64]
    assert all(float(row["mean_ms_per_op"]) > 0 for row in scaling)
    mean_svg = (ROOT / "evidence/payload-scaling/charts/mean-latency.svg").read_text()
    allocation_svg = (ROOT / "evidence/payload-scaling/charts/allocation.svg").read_text()
    tail_svg = (ROOT / "evidence/payload-scaling/charts/tail-latency.svg").read_text()
    for row in scaling:
        assert f'{float(row["mean_ms_per_op"]):,.3f}' in mean_svg
        assert f'{float(row["allocation_bytes_per_op"]):,.3f}' in allocation_svg
        if row["p95_us"]:
            assert f'{float(row["p95_us"]):,.3f}' in tail_svg
            assert f'{float(row["p99_us"]):,.3f}' in tail_svg
    soak_svg = (ROOT / "evidence/kafka-soak/charts/accounting-and-lag.svg").read_text()
    for value in ("1,080,001", "1,069,201", "10,800", "LIVE_LOCAL_VERIFIED"):
        assert value in soak_svg, f"soak chart missing {value}"


def check_live_demo() -> None:
    manifest_path = ROOT / "evidence/live-demo/video-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["schemaVersion"] == 1
    assert manifest["status"] == "PASS"
    assert re.fullmatch(r"[0-9a-f]{40}", manifest["sourceRevision"])

    for media_key in ("video", "poster"):
        media = manifest[media_key]
        path = (ROOT / media["path"]).resolve()
        assert path.is_relative_to(ROOT), f"live demo {media_key} escapes repository root"
        assert path.is_file(), f"live demo {media_key} missing: {media['path']}"
        assert digest(path) == media["sha256"], f"live demo {media_key} checksum mismatch"

    video = manifest["video"]
    assert (ROOT / video["path"]).stat().st_size == video["bytes"]
    assert video["durationSeconds"] > 19 * 60
    assert video["width"] == 1920 and video["height"] == 1200
    assert video["captionMode"].startswith("58 persistent")

    scope = manifest["scope"]
    assert scope["producerBoundary"] == "flowplane.demo.orders.raw only"
    assert scope["scriptedDownstreamWrites"] == 0
    assert {runtime["type"] for runtime in scope["runtimes"]} == {
        "apache-flink-job",
        "kafka-connect-mongodb-sink",
    }

    artifacts = manifest["artifacts"]
    assert [artifact["version"] for artifact in artifacts] == ["1.0.0", "1.1.0"]
    for artifact in artifacts:
        assert re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
        assert artifact["flink"] == {"transformed": 1, "dlq": 1}
        assert artifact["kafkaConnect"] == {"mongoDocuments": 1, "dlq": 1}

    replay = manifest["runtimeGates"]["connectCandidateReplay"]
    assert replay["recordsCompared"] == replay["matched"] + replay["expectedDifferences"] + replay["expectedTransformFailures"]
    assert replay["unexpectedDifferences"] == 0 and replay["contractViolations"] == 0
    assert manifest["runtimeGates"]["flinkDownstreamSchema"]["status"] == "PASSED"

    chapter_times = [chapter["atSeconds"] for chapter in manifest["chapters"]]
    assert chapter_times == sorted(chapter_times)
    assert chapter_times[-1] < video["durationSeconds"]

    documentation = (ROOT / manifest["documentation"]).read_text(encoding="utf-8")
    assert manifest["runId"] in documentation
    assert video["sha256"] in documentation


def check_document_links() -> None:
    link_pattern = re.compile(r"!?\[[^]]*\]\(([^)]+)\)")
    failures: list[str] = []
    for document in ROOT.rglob("*.md"):
        if ".git" in document.parts:
            continue
        for target in link_pattern.findall(document.read_text(encoding="utf-8")):
            path = target.split("#", 1)[0]
            if path and not re.match(r"^[a-z]+:", path, re.I) and not (document.parent / path).resolve().exists():
                failures.append(f"{document.relative_to(ROOT)} -> {path}")
    assert not failures, "broken Markdown links:\n" + "\n".join(failures)


if __name__ == "__main__":
    check_hashes()
    check_release_archive()
    check_claims()
    check_manifest()
    check_repeatability()
    check_soak()
    check_parity()
    check_scaling_and_charts()
    check_live_demo()
    check_document_links()
    print("Evidence validation passed: checksums, claims, statuses, manifest, qualification, accounting, parity, charts, live-demo provenance, and links.")
