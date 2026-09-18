#!/usr/bin/env python3
"""
Trims the eve-log `types:` list in suricata.yaml down to `- alert:` only.

Everything between the literal line `- alert:` and the line containing
`- tls-store:` is commented out, except lines that are already comments
or blank. This keeps Suricata's default `alert` sub-options intact and
disables every other eve-log event type (flow, dns, http, tls, stats,
etc.) without hand-editing hundreds of lines.

Usage:
    python3 comment_eve_types.py [path-to-suricata.yaml]

Defaults to /etc/suricata/suricata.yaml if no path is given.
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/etc/suricata/suricata.yaml"

with open(path) as f:
    lines = f.readlines()

start = None
end = None
for i, line in enumerate(lines):
    if start is None and line.strip() == "- alert:":
        start = i
        continue
    if start is not None and end is None and "- tls-store:" in line:
        end = i
        break

if start is None or end is None:
    print("ERROR: anchors not found, start=", start, "end=", end)
    sys.exit(1)

for i in range(start + 1, end):
    line = lines[i]
    if line.strip() == "" or line.lstrip().startswith("#"):
        continue
    indent_len = len(line) - len(line.lstrip(" "))
    indent = line[:indent_len]
    rest = line[indent_len:]
    lines[i] = indent + "#" + rest

with open(path, "w") as f:
    f.writelines(lines)

print("OK: commented lines", start + 2, "to", end,
      "(1-indexed); kept '- alert:' at line", start + 1,
      "and '- tls-store:' at line", end + 1, "untouched.")
