#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"
bda_setup_exp5() {
# 02 - Hive 3.1.2: local Derby metastore; CLI available for manual practice.
note 'HIVE 3.1.2: install, configure, initialize metastore, verify'
base_tools
load_hadoop
ensure_hdfs
HIVE_HOME=''
for d in "${BDA_HIVE_HOME:-}" "$HOME/apache-hive-3.1.2-bin" "$TOOLS/apache-hive-3.1.2-bin"; do
  if [[ -n "$d" && -f "$d/lib/hive-common-3.1.2.jar" && -x "$d/bin/hive" ]]; then HIVE_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$HIVE_HOME" ]] && command -v hive >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v hive)")")")"
  [[ -f "$d/lib/hive-common-3.1.2.jar" ]] && HIVE_HOME="$d"
fi
if [[ -z "$HIVE_HOME" ]]; then
  HIVE_HOME="$HOME/apache-hive-3.1.2-bin"
  if [[ -e "$HIVE_HOME" ]]; then
    note 'Backing up incomplete Hive extraction before reinstalling.'
    mv "$HIVE_HOME" "$ROOT/backups/hive-incomplete.$(date +%Y%m%d%H%M%S).$$"
  fi
  ARC="$CACHE/apache-hive-3.1.2-bin.tar.gz"
  archive_download "$ARC" \
    'https://mirrors.huaweicloud.com/repository/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz' \
    'https://repo.huaweicloud.com/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz' \
    'https://archive.apache.org/dist/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz'
  archive_install "$ARC" apache-hive-3.1.2-bin "$HIVE_HOME"
fi
export HIVE_HOME PATH="$HIVE_HOME/bin:$PATH"
write_profile 20_hive.sh "export HIVE_HOME='$HIVE_HOME'" 'export PATH="$HIVE_HOME/bin:$PATH"'
# Hive 3.1.2 bundles Guava 19; Hadoop 3.2.3 uses Guava 27. Match Hadoop to avoid NoSuchMethodError.
shopt -s nullglob
HGUAVAS=( "$HADOOP_HOME"/share/hadoop/common/lib/guava-*.jar )
((${#HGUAVAS[@]}==1)) || fail 'Expected exactly one Hadoop Guava JAR; inspect Hadoop installation.'
for jar in "$HIVE_HOME"/lib/guava-*.jar; do
  if [[ "$(basename "$jar")" != "$(basename "${HGUAVAS[0]}")" ]]; then
    backup "$jar"; if [[ -w "$jar" ]]; then rm -f "$jar"; else need_sudo rm -f "$jar"; fi
  fi
done
if [[ ! -f "$HIVE_HOME/lib/$(basename "${HGUAVAS[0]}")" ]]; then
  if [[ -w "$HIVE_HOME/lib" ]]; then cp "${HGUAVAS[0]}" "$HIVE_HOME/lib/"; else need_sudo cp "${HGUAVAS[0]}" "$HIVE_HOME/lib/"; fi
fi
shopt -u nullglob
# Initialize a lab-owned Derby metastore. Recovery moves failed metadata
# to a timestamped backup. Unknown/external metastores are never changed.
METASTORE="$ROOT/hive/metastore_db"
mkdir -p "$ROOT/hive"
if [[ ! -f "$HIVE_HOME/conf/hive-site.xml" ]] || ! grep -q 'javax.jdo.option.ConnectionURL' "$HIVE_HOME/conf/hive-site.xml"; then
  backup "$HIVE_HOME/conf/hive-site.xml"
  safe_write "$HIVE_HOME/conf/hive-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:derby:;databaseName=$METASTORE;create=true</value></property>
  <property><name>javax.jdo.option.ConnectionDriverName</name><value>org.apache.derby.jdbc.EmbeddedDriver</value></property>
  <property><name>hive.metastore.warehouse.dir</name><value>/user/hive/warehouse</value></property>
  <property><name>hive.metastore.schema.verification</name><value>true</value></property>
</configuration>
XML
else
  warn 'Existing Hive metastore settings found; retaining your hive-site.xml.'
fi
"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /tmp /user/hive/warehouse
"$HADOOP_HOME/bin/hdfs" dfs -chmod 1777 /tmp || warn 'Could not change /tmp permissions (may belong to an administrator).'
"$HADOOP_HOME/bin/hdfs" dfs -chmod 775 /user/hive/warehouse || warn 'Could not change warehouse permissions.'
# Hive's -info may CREATE an empty metastore_db when create=true. Do NOT
# treat that side-effect as proof that existing tables need to be preserved.
# Repair only the directory matching the script's known lab-owned URL.
SCHEMA_LOG="$ROOT/logs/hive-schema-$(date +%Y%m%d-%H%M%S).log"
MANAGED_HIVE=0
if grep -Fq "databaseName=$METASTORE;create=true" "$HIVE_HOME/conf/hive-site.xml"; then
  MANAGED_HIVE=1
fi
hive_schema_check() { "$HIVE_HOME/bin/schematool" -dbType derby -info >"$SCHEMA_LOG" 2>&1; }
hive_schema_init() { "$HIVE_HOME/bin/schematool" -dbType derby -initSchema >>"$SCHEMA_LOG" 2>&1; }
if hive_schema_check; then
  note 'Hive Derby schema already valid.'
else
  (( MANAGED_HIVE )) || { tail -n 25 "$SCHEMA_LOG" >&2; fail 'Unknown Hive metastore configuration. It cannot be reset safely.'; }
  if [[ -e "$METASTORE" ]]; then
    OLD="$ROOT/backups/hive-metastore.$(date +%Y%m%d-%H%M%S).$$"
    # Preserve entire database and logs; move rather than deleting.
    note "Schema invalid. Moving lab metastore to backup: $OLD"
    mv "$METASTORE" "$OLD"
  fi
  note 'Initializing a fresh Hive Derby metastore schema.'
  if ! hive_schema_init; then
    # A failed init can leave another partial Derby DB. Back it up and
    # retry once, but do not loop indefinitely.
    warn 'First schema initialization failed; backing up partial schema and retrying once.'
    if [[ -e "$METASTORE" ]]; then
      mv "$METASTORE" "$ROOT/backups/hive-metastore-partial.$(date +%Y%m%d-%H%M%S).$$"
    fi
    hive_schema_init || { tail -n 40 "$SCHEMA_LOG" >&2; fail "Hive schema creation failed. Log: $SCHEMA_LOG"; }
  fi
  hive_schema_check || { tail -n 40 "$SCHEMA_LOG" >&2; fail "Hive schema verification failed: $SCHEMA_LOG"; }
fi
note 'Hive CLI smoke test: SHOW DATABASES;'
if ! timeout 180 "$HIVE_HOME/bin/hive" -e 'SHOW DATABASES;'; then
  warn 'Hive CLI failed once. Rechecking HDFS scratch folders and retrying.'
  "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /tmp /user/hive/warehouse
  "$HADOOP_HOME/bin/hdfs" dfs -chmod 1777 /tmp || true
  timeout 180 "$HIVE_HOME/bin/hive" -e 'SHOW DATABASES;' || fail "Hive CLI failed after repair. See $SCHEMA_LOG and Hive's actual error output."
fi
note 'HIVE READY. New terminal: hive  (then SHOW DATABASES; or CREATE DATABASE my_db;)'

}

bda_init_lab 'EXPERIMENT 5 — Hive installation and HiveQL'
bda_setup_exp5
bda_ready_yarn
bda_step 'hive --version' hive --version

# Use ONE genuine interactive Hive CLI session for every HiveQL statement.
# Python's built-in PTY keeps the real hive> prompt and actual Hive output.
# The same silent Enter and 40 ms/character typing are preserved.
bda_hive_console() {
  BDA_HIVE_CONSOLE_BIN="$HIVE_HOME/bin/hive" \
  BDA_HIVE_CONSOLE_DELAY="${BDA_TYPING_DELAY:-0.04}" \
  BDA_HIVE_CONSOLE_AUTO="${BDA_AUTO:-0}" \
  python3 - <<'PYHIVE'
import errno
import os
import pty
import re
import select
import signal
import sys
import termios
import time

commands = [
    "CREATE DATABASE IF NOT EXISTS my_db;",
    "SHOW DATABASES;",
    "USE my_db;",
    "CREATE TABLE IF NOT EXISTS employee (id INT, name STRING, age INT, salary DOUBLE, dept STRING) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE;",
    "SHOW TABLES;",
    "DESCRIBE employee;",
    # The existing experiment truncates only its own sample table on rerun.
    "TRUNCATE TABLE employee;",
    "INSERT INTO TABLE employee VALUES (1, 'Alice', 24, 42000.0, 'Engineering'), (2, 'Bob', 29, 51000.0, 'Sales'), (3, 'Carol', 33, 63000.0, 'Engineering'), (4, 'David', 27, 56000.0, 'Support');",
    "SELECT * FROM employee;",
    "SELECT name, salary FROM employee WHERE salary > 50000;",
    "SELECT * FROM employee ORDER BY salary DESC LIMIT 3;",
    "SELECT dept, COUNT(*), AVG(salary) FROM employee GROUP BY dept;",
]

cli = os.environ['BDA_HIVE_CONSOLE_BIN']
auto = os.environ.get('BDA_HIVE_CONSOLE_AUTO') == '1'
delay = float(os.environ.get('BDA_HIVE_CONSOLE_DELAY', '0.04'))
# The actual Hive CLI may show hive> or hive (my_db)>.
PROMPT = re.compile(rb'hive(?:\s+\([^\r\n]*\))?>[ \t]*$')
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
FAILURE = re.compile(rb'(?im)^\s*(?:FAILED:|Error executing|Error while compiling)')

pid, master = pty.fork()
if pid == 0:
    os.execv(cli, [cli])


def wait_for_prompt(seconds):
    end = time.monotonic() + seconds
    tail = bytearray()
    while time.monotonic() < end:
        readable, _, _ = select.select([master], [], [], min(1.0, max(0, end - time.monotonic())))
        if not readable:
            continue
        try:
            chunk = os.read(master, 16384)
        except OSError as exc:
            if exc.errno == errno.EIO:
                raise RuntimeError('Hive shell closed before returning a prompt') from exc
            raise
        if not chunk:
            raise RuntimeError('Hive shell closed unexpectedly')
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        tail.extend(chunk)
        if len(tail) > 131072:
            del tail[:-131072]
        plain = ANSI.sub(b'', bytes(tail)).replace(b'\r', b'')
        if PROMPT.search(plain):
            return plain
    raise TimeoutError('Timed out waiting for the Hive console prompt')


def wait_for_enter():
    if auto:
        return
    try:
        fd = os.open('/dev/tty', os.O_RDONLY)
    except OSError:
        return  # no controlling terminal (e.g. a CI test)
    previous = termios.tcgetattr(fd)
    try:
        altered = previous.copy()
        altered[3] &= ~termios.ECHO  # retain canonical input and Ctrl+C
        termios.tcsetattr(fd, termios.TCSANOW, altered)
        ready, _, _ = select.select([fd], [], [], float(os.environ.get('BDA_ENTER_TIMEOUT', '3')))
        if not ready:
            return  # after 3 seconds, execute without requiring Enter
        line = os.read(fd, 4096)
        if not line:
            return
        if line.strip().lower() == b'q':
            raise KeyboardInterrupt
        if line.strip():
            raise ValueError('Press Enter alone to execute the statement')
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, previous)
        os.close(fd)


def send_sql(sql):
    for character in sql:
        os.write(master, character.encode('utf-8'))
        if not auto and delay > 0:
            time.sleep(delay)
    os.write(master, b'\r')
    result = wait_for_prompt(600)
    if FAILURE.search(result):
        raise RuntimeError('Hive reported an SQL error; stopping to avoid incorrect results')


try:
    wait_for_prompt(180)
    for sql in commands:
        wait_for_enter()
        send_sql(sql)
    os.write(master, b'exit;\r')
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            if os.waitstatus_to_exitcode(status) not in (0, 1):
                raise RuntimeError('Hive console exited abnormally')
            break
        time.sleep(0.15)
    else:
        os.kill(pid, signal.SIGTERM)
        raise RuntimeError('Hive console did not exit after the last query')
except (KeyboardInterrupt, EOFError):
    # No final prompt or banner; close the lab console on user interruption.
    try:
        os.write(master, b'exit;\r')
    except OSError:
        pass
    sys.exit(130)
except (RuntimeError, TimeoutError, ValueError) as exc:
    print(f'\n[ERROR] {exc}', file=sys.stderr)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    sys.exit(1)
finally:
    os.close(master)
PYHIVE
}

bda_step 'hive' bda_hive_console
bda_finished
