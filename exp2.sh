#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"

bda_init_lab 'EXPERIMENT 2 — HDFS create/upload/download/delete'
bda_ready_hadoop
bda_step "mkdir -p ~/bda-exp-work/exp2" mkdir -p "$BDA_HOME/exp2"
bda_shell "printf 'File systems organize information.\nThis is a sample HDFS text file.\n' > ~/bda-exp-work/exp2/data.txt"   'printf "File systems organize information.\nThis is a sample HDFS text file.\n" > "$BDA_HOME/exp2/data.txt"'
bda_step 'cat ~/bda-exp-work/exp2/data.txt' cat "$BDA_HOME/exp2/data.txt"
bda_step "hadoop fs -mkdir -p $BDA_HDFS_ROOT/exp2/input" hadoop fs -mkdir -p "$BDA_HDFS_ROOT/exp2/input"
bda_step "hadoop fs -put -f ~/bda-exp-work/exp2/data.txt $BDA_HDFS_ROOT/exp2/input/" hadoop fs -put -f "$BDA_HOME/exp2/data.txt" "$BDA_HDFS_ROOT/exp2/input/data.txt"
bda_step "hadoop fs -ls $BDA_HDFS_ROOT/exp2/input" hadoop fs -ls "$BDA_HDFS_ROOT/exp2/input"
bda_step "hadoop fs -cat $BDA_HDFS_ROOT/exp2/input/data.txt" hadoop fs -cat "$BDA_HDFS_ROOT/exp2/input/data.txt"
bda_step "hadoop fs -get -f $BDA_HDFS_ROOT/exp2/input/data.txt ~/bda-exp-work/exp2/copy.txt" hadoop fs -get -f "$BDA_HDFS_ROOT/exp2/input/data.txt" "$BDA_HOME/exp2/copy.txt"
bda_step 'cat ~/bda-exp-work/exp2/copy.txt' cat "$BDA_HOME/exp2/copy.txt"
bda_step "hadoop fs -rm -f $BDA_HDFS_ROOT/exp2/input/data.txt" hadoop fs -rm -f "$BDA_HDFS_ROOT/exp2/input/data.txt"
bda_step "hadoop fs -rmdir $BDA_HDFS_ROOT/exp2/input" hadoop fs -rmdir "$BDA_HDFS_ROOT/exp2/input"
bda_finished
