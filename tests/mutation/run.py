import json, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mutations import MUTATIONS

source, work, out, udid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
check_only = len(sys.argv) > 5 and sys.argv[5] == "check"
only = sys.argv[5][5:].split(",") if len(sys.argv) > 5 and sys.argv[5].startswith("only=") else None
os.makedirs(out, exist_ok=True)
summary = []
for m in MUTATIONS:
    if only and not any(m["name"].startswith(prefix) for prefix in only):
        continue
    path = os.path.join(source, "src/ios", m["file"])
    text = open(path).read()
    count = text.count(m["old"])
    if count == 0 or (count > 1 and not m.get("all")):
        print(f"PATCH-MISMATCH {m['name']} count={count}")
        sys.exit(1)
    if check_only:
        print(f"ok {m['name']} ({count})")
        continue
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(os.path.join(source, "src/ios"), work)
    target = os.path.join(work, m["file"])
    mutated = open(target).read().replace(m["old"], m["new"])
    open(target, "w").write(mutated)
    args = ["xcodebuild", "test", "-scheme", "ThermalPrinter", "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", os.path.expanduser("~/work/tp/dd-mutation")]
    args += [f"-only-testing:{t}" for t in m["tests"]]
    result = subprocess.run(args, cwd=work, capture_output=True, text=True)
    log = result.stdout + result.stderr
    failures = sorted(set(re.findall(r"Test Case '-\[ThermalPrinterTests\.(\w+) (\w+)\]' failed", log)))
    passes = sorted(set(re.findall(r"Test Case '-\[ThermalPrinterTests\.(\w+) (\w+)\]' passed", log)))
    assertions = [l.strip()[:400] for l in log.splitlines() if " error: -[ThermalPrinterTests." in l]
    expected = sorted({tuple(t.split("/")[1:3]) for t in m["tests"]})
    caught = all(e in failures for e in expected)
    with open(os.path.join(out, m["name"] + ".log"), "w") as f:
        f.write(f"mutation: {m['name']} (review round {m['round']})\nfile: {m['file']}\n--- original\n{m['old']}\n+++ mutated\n{m['new']}\n\n")
        f.write("tests run: " + ", ".join(t.split('/', 1)[1] for t in m["tests"]) + "\n")
        f.write("failed: " + ", ".join(".".join(x) for x in failures) + "\n")
        f.write("passed: " + ", ".join(".".join(x) for x in passes) + "\n\n")
        f.write("\n".join(assertions[:40]) + "\n\n")
        f.write("\n".join(l for l in log.splitlines() if "Executed" in l or "TEST FAILED" in l or "TEST SUCCEEDED" in l or "error:" in l and "ThermalPrinterTests" not in l)[:4000] + "\n")
    summary.append({"mutation": m["name"], "round": m["round"], "tests": [t.split('/', 1)[1] for t in m["tests"]], "failed": [".".join(x) for x in failures], "all_expected_failed": caught})
    print(("CAUGHT " if caught else "MISSED ") + m["name"] + " failed=" + ",".join(".".join(x) for x in failures), flush=True)
summary_path = os.path.join(out, "summary.json")
previous = json.load(open(summary_path)) if os.path.exists(summary_path) else []
merged = {item["mutation"]: item for item in previous}
merged.update({item["mutation"]: item for item in summary})
json.dump([merged[key] for key in sorted(merged)], open(summary_path, "w"), indent=1)
