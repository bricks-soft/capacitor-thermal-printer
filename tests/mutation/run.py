import importlib
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
MUTATIONS = importlib.import_module(os.environ.get("MUTATIONS_MODULE", "mutations")).MUTATIONS

source, work, out, udid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
option = sys.argv[5] if len(sys.argv) > 5 else ""
check_only = option == "check"
only = option[5:].split(",") if option.startswith("only=") else None
derived_data = os.path.expanduser(os.environ.get("MUTATION_DERIVED_DATA", "~/work/tp/dd-mutation"))
os.makedirs(out, exist_ok=True)

summary = []
problems = []
for m in MUTATIONS:
    if only and not any(m["name"].startswith(prefix) for prefix in only):
        continue
    path = os.path.join(source, "ios", m["file"])
    text = open(path).read()
    count = text.count(m["old"])
    if count == 0 or (count > 1 and not m.get("all")):
        print(f"PATCH-MISMATCH {m['name']} count={count}", flush=True)
        problems.append(m["name"])
        continue
    if check_only:
        print(f"ok {m['name']} ({count})", flush=True)
        continue
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(source, work, ignore=shutil.ignore_patterns(".git", "node_modules", ".build", ".swiftpm", "dist", "build", ".gradle"))
    target = os.path.join(work, "ios", m["file"])
    original = open(target).read()
    with open(target, "w") as handle:
        handle.write(original.replace(m["old"], m["new"]))
    args = ["xcodebuild", "test", "-scheme", "BricksSoftCapacitorThermalPrinter", "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", derived_data]
    args += [f"-only-testing:{t}" for t in m["tests"]]
    result = subprocess.run(args, cwd=work, capture_output=True, text=True)
    log = result.stdout + result.stderr
    pattern = r"Test Case '-\[ThermalPrinterTests\.(\w+) (\w+)\]' {}"
    started = set(re.findall(pattern.format("started"), log))
    failures = sorted(set(re.findall(pattern.format("failed"), log)))
    passes = sorted(set(re.findall(pattern.format("passed"), log)))
    expected = sorted({tuple(t.split("/")[1:3]) for t in m["tests"]})
    if not all(e in started for e in expected):
        status = "INFRA"
    elif all(e in failures for e in expected):
        status = "CAUGHT"
    else:
        status = "MISSED"
    if status != "CAUGHT":
        problems.append(m["name"])
    assertions = [line.strip()[:400] for line in log.splitlines() if " error: -[ThermalPrinterTests." in line]
    build_errors = [line.strip()[:400] for line in log.splitlines() if ": error: " in line and "ThermalPrinterTests." not in line]
    with open(os.path.join(out, m["name"] + ".log"), "w") as f:
        f.write(f"mutation: {m['name']} (review round {m['round']})\nstatus: {status}\nfile: {m['file']}\n--- original\n{m['old']}\n+++ mutated\n{m['new']}\n\n")
        f.write("tests run: " + ", ".join(t.split("/", 1)[1] for t in m["tests"]) + "\n")
        f.write("failed: " + ", ".join(".".join(x) for x in failures) + "\n")
        f.write("passed: " + ", ".join(".".join(x) for x in passes) + "\n\n")
        f.write("\n".join(assertions[:40] + build_errors[:20]) + "\n\n")
        f.write("\n".join(line for line in log.splitlines() if "Executed" in line or "** TEST" in line)[:4000] + "\n")
    summary.append({"mutation": m["name"], "round": m["round"], "status": status, "tests": [t.split("/", 1)[1] for t in m["tests"]], "failed": [".".join(x) for x in failures]})
    print(f"{status} {m['name']} failed=" + ",".join(".".join(x) for x in failures), flush=True)

if not check_only:
    summary_path = os.path.join(out, "summary.json")
    previous = json.load(open(summary_path)) if os.path.exists(summary_path) else []
    merged = {item["mutation"]: item for item in previous}
    merged.update({item["mutation"]: item for item in summary})
    json.dump([merged[key] for key in sorted(merged)], open(summary_path, "w"), indent=1)

if problems:
    print(f"FAILED: {len(problems)} mutation(s) not caught or not run: " + ", ".join(problems), flush=True)
    sys.exit(1)
print("OK: every patch applies" if check_only else "OK: every selected mutation was caught", flush=True)
