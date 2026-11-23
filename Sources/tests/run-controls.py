#!/usr/bin/env python3
"""Exercise the candidate's extracted gesture methods without touching live state."""
from pathlib import Path
import hashlib
import re
import subprocess
import sys
import tempfile

test_dir = Path(__file__).resolve().parent
source_path = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else test_dir.parent / "caps-mute-menubar.swift"
source = source_path.read_text()


def method(name):
    match = re.search(r"(?m)^    (?:@objc )?func " + re.escape(name) + r"\b", source)
    if not match:
        raise RuntimeError(f"Candidate does not define {name}")
    opening = source.index("{", match.start())
    depth = 0
    quoted = False
    escaped = False
    line_comment = False
    i = opening
    while i < len(source):
        c = source[i]
        if line_comment:
            if c == "\n":
                line_comment = False
        elif quoted:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quoted = False
        elif source.startswith("//", i):
            line_comment = True
            i += 1
        elif c == '"':
            quoted = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():i + 1]
        i += 1
    raise RuntimeError(f"Unterminated method {name}")


properties = source.split("    // Control-tap detector state\n", 1)[1].split("    override init()", 1)[0]
method_names = ["controlTapped", "refreshSoon", "togglePause", "toggleMute"]
# Include any dedicated helpers added alongside the extracted gesture methods.
control_section = source.split("    func controlTapped", 1)[1].split("    @objc func clicked", 1)[0]
for helper in re.findall(r"(?m)^    (?:@objc )?func (\w+)", control_section):
    if helper not in method_names:
        method_names.append(helper)
method_names.extend(sys.argv[2:])
method_names = list(dict.fromkeys(method_names))
methods = "\n\n".join(method(name) for name in method_names)
harness = (test_dir / "scenarios.swift").read_text()
harness = harness.replace("// EXTRACTED_PROPERTIES", properties)
harness = harness.replace("// EXTRACTED_METHODS", methods)
with tempfile.TemporaryDirectory(prefix="poliwhirl-controls-") as output:
    generated = Path(output) / "extracted-controls.swift"
    generated.write_text(harness)
    binary = Path(output) / "controls-tests"
    print(f"Testing actual source: {source_path}", flush=True)
    print(f"SHA-256: {hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    print(f"Extracted methods: {', '.join(method_names)}", flush=True)
    subprocess.run(["swiftc", "-swift-version", "5", "-framework", "Cocoa", "-framework", "CoreGraphics",
                    str(generated), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
