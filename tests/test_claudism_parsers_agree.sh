#!/bin/bash
# The claudism list has ONE declared shape and two readers: the mirror reads it
# before I speak, the capture reads it after. They are meant to be identical
# line for line, and twice today they were not — the backreference clause lived
# in one copy for three hours (ca1c488, then 1215df6). This test is the seam
# itself, MIN-34: the shared functions must agree as code, docstrings and
# comments aside, or the drift is a failure and not a follow-up.
# Run: bash tests/test_claudism_parsers_agree.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

for fn in load_patterns classify_use sentences; do
    out=$(python3 - "$SANDBOX_REPO/lib/claudism-capture" \
                    "$SANDBOX_REPO/lib/claudism-mirror" "$fn" <<'EOF'
import ast, sys

def body(path, name):
    tree = ast.parse(open(path).read())
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            stmts = list(node.body)
            # The mirror's copy carries a docstring the capture's does not;
            # prose about the seam is not drift in the seam.
            if (stmts and isinstance(stmts[0], ast.Expr)
                    and isinstance(stmts[0].value, ast.Constant)
                    and isinstance(stmts[0].value.value, str)):
                stmts = stmts[1:]
            return "\n".join(ast.dump(s, indent=1) for s in stmts)
    return ""

cap, mir, name = sys.argv[1], sys.argv[2], sys.argv[3]
a, b = body(cap, name), body(mir, name)
if not a or not b:
    print("MISSING")
elif a == b:
    print("AGREE")
else:
    print("DRIFT")
EOF
)
    check "the two parsers' $fn() is the same code" [ "$out" = AGREE ]
done

# And the clause that started this: a replacement holding a backreference is
# spliced literally, so it must be refused by BOTH readers, not just the one.
for f in claudism-capture claudism-mirror; do
    check "$f refuses a backreference replacement" \
        contains "$(cat "$SANDBOX_REPO/lib/$f")" 'if re.search(r"\\[0-9g]", m.group(2)):'
done
