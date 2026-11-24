#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"

bda_init_lab 'EXPERIMENT 3 — Matrix multiplication using Hadoop Streaming'
bda_ready_hadoop
bda_ready_yarn
command -v python3 >/dev/null || install_pkgs python3
WORK="$BDA_HOME/exp3"
bda_step 'mkdir -p ~/bda-exp-work/exp3' mkdir -p "$WORK"
bda_shell "cat > ~/bda-exp-work/exp3/matrix_input.txt <<EOF  # A/B matrices"   'cat > "$BDA_HOME/exp3/matrix_input.txt" <<"EOF"
A,0,0,2
A,0,1,1
A,1,0,3
A,1,1,2
B,0,0,4
B,0,1,3
B,1,0,1
B,1,1,5
EOF'
# Write authentic mapper / reducer source files from here-documents.
write_matrix_code() {
  cat > "$WORK/mapper.py" <<'PYMAP'
#!/usr/bin/env python3
"""Matrix A*B: distribute A(i,j) and B(j,k) to output cell key (i,k)."""
import sys

ROWS_A = 2
COLS_B = 2

for line in sys.stdin:
    if not line.strip():
        continue
    name, row, col, value = line.strip().split(",")
    if name == "A":
        for k in range(COLS_B):
            print(f"{row},{k}\tA,{col},{value}")
    elif name == "B":
        for i in range(ROWS_A):
            print(f"{i},{col}\tB,{row},{value}")
    else:
        raise ValueError(f"Unknown matrix: {name}")
PYMAP
  cat > "$WORK/reducer.py" <<'PYRED'
#!/usr/bin/env python3
"""Combine sorted mapper records and multiply matching A(i,j)*B(j,k)."""
import sys
from itertools import groupby


def records():
    for line in sys.stdin:
        if not line.strip():
            continue
        key, entry = line.rstrip("\n").split("\t", 1)
        name, index, value = entry.split(",")
        yield key, name, int(index), int(value)


for cell, group in groupby(records(), key=lambda item: item[0]):
    a_values = {}
    b_values = {}
    for _, name, index, value in group:
        (a_values if name == "A" else b_values)[index] = value
    result = sum(v * b_values.get(j, 0) for j, v in a_values.items())
    print(f"{cell}\t{result}")
PYRED
  chmod +x "$WORK/mapper.py" "$WORK/reducer.py"
}
bda_step 'cat > mapper.py <<PYMAP ; cat > reducer.py <<PYRED  # write Python programs' write_matrix_code
bda_step 'cat ~/bda-exp-work/exp3/mapper.py' cat "$WORK/mapper.py"
bda_step 'cat ~/bda-exp-work/exp3/reducer.py' cat "$WORK/reducer.py"
bda_shell 'python3 mapper.py < matrix_input.txt | sort | python3 reducer.py'   'python3 "$BDA_HOME/exp3/mapper.py" < "$BDA_HOME/exp3/matrix_input.txt" | sort | python3 "$BDA_HOME/exp3/reducer.py"'
bda_step "hadoop fs -mkdir -p $BDA_HDFS_ROOT/exp3/input" hadoop fs -mkdir -p "$BDA_HDFS_ROOT/exp3/input"
bda_step "hadoop fs -put -f ~/bda-exp-work/exp3/matrix_input.txt $BDA_HDFS_ROOT/exp3/input/matrix_input.txt" hadoop fs -put -f "$WORK/matrix_input.txt" "$BDA_HDFS_ROOT/exp3/input/matrix_input.txt"
bda_step "hadoop fs -rm -r -f $BDA_HDFS_ROOT/exp3/output" hadoop fs -rm -r -f "$BDA_HDFS_ROOT/exp3/output"
bda_step "hadoop jar \"$HADOOP_STREAMING\" -files \"$WORK/mapper.py,$WORK/reducer.py\" -input $BDA_HDFS_ROOT/exp3/input -output $BDA_HDFS_ROOT/exp3/output -mapper 'python3 mapper.py' -reducer 'python3 reducer.py'"   hadoop jar "$HADOOP_STREAMING" -D mapreduce.job.reduces=1 -files "$WORK/mapper.py,$WORK/reducer.py"   -input "$BDA_HDFS_ROOT/exp3/input" -output "$BDA_HDFS_ROOT/exp3/output"   -mapper 'python3 mapper.py' -reducer 'python3 reducer.py'
bda_step "hadoop fs -cat $BDA_HDFS_ROOT/exp3/output/part-00000" hadoop fs -cat "$BDA_HDFS_ROOT/exp3/output/part-00000"
verify_matrix() {
  hadoop fs -cat "$BDA_HDFS_ROOT/exp3/output/part-00000" > "$WORK/result.txt"
  printf '0,0\t9\n0,1\t11\n1,0\t14\n1,1\t19\n' > "$WORK/expected.txt"
  diff -u "$WORK/expected.txt" "$WORK/result.txt"
}
bda_step 'diff -u expected.txt result.txt # verify computed matrix' verify_matrix
bda_finished
