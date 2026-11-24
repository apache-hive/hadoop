#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"

bda_init_lab 'EXPERIMENT 4 — WordCount (built-in Hadoop MapReduce)'
bda_ready_hadoop
bda_ready_yarn
bda_step 'mkdir -p ~/bda-exp-work/exp4' mkdir -p "$BDA_HOME/exp4"
bda_shell "cat > ~/bda-exp-work/exp4/word_input.txt <<EOF"   'cat > "$BDA_HOME/exp4/word_input.txt" <<"EOF"
cloud data grows daily
hadoop stores cloud data
mapreduce counts data words
hadoop processes data using mapreduce
EOF'
bda_step 'cat ~/bda-exp-work/exp4/word_input.txt' cat "$BDA_HOME/exp4/word_input.txt"
bda_step "hadoop fs -mkdir -p $BDA_HDFS_ROOT/exp4/input" hadoop fs -mkdir -p "$BDA_HDFS_ROOT/exp4/input"
bda_step "hadoop fs -put -f ~/bda-exp-work/exp4/word_input.txt $BDA_HDFS_ROOT/exp4/input/word_input.txt" hadoop fs -put -f "$BDA_HOME/exp4/word_input.txt" "$BDA_HDFS_ROOT/exp4/input/word_input.txt"
bda_step "hadoop fs -rm -r -f $BDA_HDFS_ROOT/exp4/output" hadoop fs -rm -r -f "$BDA_HDFS_ROOT/exp4/output"
bda_step "hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.2.3.jar wordcount $BDA_HDFS_ROOT/exp4/input $BDA_HDFS_ROOT/exp4/output"  hadoop jar "$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.2.3.jar" wordcount "$BDA_HDFS_ROOT/exp4/input" "$BDA_HDFS_ROOT/exp4/output"
bda_step "hadoop fs -ls $BDA_HDFS_ROOT/exp4/output" hadoop fs -ls "$BDA_HDFS_ROOT/exp4/output"
bda_step "hadoop fs -cat $BDA_HDFS_ROOT/exp4/output/part-r-00000" hadoop fs -cat "$BDA_HDFS_ROOT/exp4/output/part-r-00000"
verify_wordcount() {
  local file="$BDA_HOME/exp4/wordcount_result.txt"
  hadoop fs -cat "$BDA_HDFS_ROOT/exp4/output/part-r-00000" > "$file"
  grep -Fxq $'data\t4' "$file" && grep -Fxq $'hadoop\t2' "$file" && grep -Fxq $'mapreduce\t2' "$file" || fail 'WordCount results do not match the sample input.'
}
bda_step 'grep -E "data|hadoop|mapreduce" wordcount_result.txt # verify counts' verify_wordcount
bda_finished
