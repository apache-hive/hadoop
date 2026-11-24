#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"
# Check the real active-master registration, not just a Java PID.
# A shell may print a ZooKeeper exception and still return exit code zero,
# so require positive evidence in its output.
bda_hbase_status_check() {
  local out="$ROOT/logs/hbase-health-last.log" rc=0
  printf 'status "simple"\nexit\n' |
    timeout --foreground -k 5s "${BDA_HBASE_PROBE_TIMEOUT:-85}" "$HBASE_HOME/bin/hbase" shell -n >"$out" 2>&1 || rc=$?
  # HBase 2.4 can return 1 after an explicit `exit` even after a
  # successful shell command. Trust positive master + server evidence,
  # never an exit status alone; a timeout (124/137) is still a failure.
  if (( rc == 0 || rc == 1 )) && grep -q 'active master:' "$out" &&
      grep -Eq '[1-9][0-9]* live servers?' "$out" &&
      ! grep -Eiq 'Unhandled Java exception|KeeperException|MasterNotRunningException|PleaseHoldException|ERROR.*Exception|ERROR.*Failed' "$out"; then
    return 0
  fi
  return 1
}

bda_hbase_status_wait() {
  local i
  for i in 1 2 3; do
    if bda_hbase_status_check; then return 0; fi
    (( i == 3 )) || sleep "${BDA_HBASE_PROBE_INTERVAL:-8}"
  done
  return 1
}

# Only attempt an automatic restart on the isolated HBase created for this lab.
# Avoid interfering with other HBase installations on the same machine.
bda_hbase_owned_processes() {
  local pid label args
  while read -r pid label _; do
    case "$label" in
      HMaster|HRegionServer|HQuorumPeer|ThriftServer)
        args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
        if [[ "$args" != *"$HBASE_HOME"* ]]; then
          warn "An HBase daemon ($label PID $pid) may belong to another installation."
          return 1
        fi
        ;;
    esac
  done < <("$JAVA_HOME/bin/jps")
  return 0
}

bda_hbase_master_logs() {
  local last_log
  last_log="$(find "$HBASE_HOME/logs" -maxdepth 1 -type f -name '*master*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  if [[ -n "$last_log" && -f "$last_log" ]]; then
    printf '\n[ERROR] HBase master log (%s):\n' "$last_log" >&2
    tail -n 35 "$last_log" >&2
  fi
  if [[ -f "$ROOT/logs/hbase-health-last.log" ]]; then
    printf '\n[ERROR] Last HBase client check:\n' >&2
    tail -n 18 "$ROOT/logs/hbase-health-last.log" >&2
  fi
}

bda_setup_exp6() {
# 03 - HBase 2.4.18: HDFS-backed single-node HBase and Thrift.
note 'HBASE 2.4.18: install, configure, start HMaster / RegionServer / Thrift'
base_tools
load_hadoop
ensure_hdfs
require_cmd thrift thrift-compiler
HBASE_HOME=''
for d in "${BDA_HBASE_HOME:-}" "$HOME/hbase-2.4.18" "$TOOLS/hbase-2.4.18"; do
  if [[ -n "$d" && -f "$d/lib/hbase-common-2.4.18.jar" && -x "$d/bin/hbase" ]]; then HBASE_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$HBASE_HOME" ]] && command -v hbase >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v hbase)")")")"
  [[ -f "$d/lib/hbase-common-2.4.18.jar" ]] && HBASE_HOME="$d"
fi
if [[ -z "$HBASE_HOME" ]]; then
  HBASE_HOME="$HOME/hbase-2.4.18"
  if [[ -e "$HBASE_HOME" ]]; then
    note 'Backing up incomplete HBase extraction before reinstalling.'
    mv "$HBASE_HOME" "$ROOT/backups/hbase-incomplete.$(date +%Y%m%d%H%M%S).$$"
  fi
  ARC="$CACHE/hbase-2.4.18-bin.tar.gz"
  archive_download "$ARC" \
    'https://repo.huaweicloud.com/apache/hbase/2.4.18/hbase-2.4.18-bin.tar.gz' \
    'https://mirrors.huaweicloud.com/repository/apache/hbase/2.4.18/hbase-2.4.18-bin.tar.gz' \
    'https://archive.apache.org/dist/hbase/2.4.18/hbase-2.4.18-bin.tar.gz'
  archive_install "$ARC" hbase-2.4.18 "$HBASE_HOME"
fi
export HBASE_HOME HBASE_CONF_DIR="$HBASE_HOME/conf" PATH="$HBASE_HOME/bin:$PATH"
write_profile 30_hbase.sh "export HBASE_HOME='$HBASE_HOME'" 'export HBASE_CONF_DIR="$HBASE_HOME/conf"' 'export PATH="$HBASE_HOME/bin:$PATH"'
# HBase 2.4's automatic Hadoop lookup invokes GetJavaProperty through Hadoop 3.
# That invokes the invalid HADOOP_ORG.APACHE..._USER variable visible in VM logs.
# Disable the lookup; use HBase's own HDFS client jars and the actual Hadoop conf.
# Patch only a prior BDA-managed block; do not rewrite unrelated user settings.
HBASE_ENV_FILE="$HBASE_HOME/conf/hbase-env.sh"
if grep -q '^# BDA-HBASE' "$HBASE_ENV_FILE"; then
  if ! grep -q '^# BDA-HBASE-COMPAT-FIX' "$HBASE_ENV_FILE"; then
    backup "$HBASE_ENV_FILE"
    safe_append "$HBASE_ENV_FILE" <<ENV
# BDA-HBASE-COMPAT-FIX
export JAVA_HOME='$JAVA_HOME'
export HBASE_MANAGES_ZK=true
export HBASE_DISABLE_HADOOP_CLASSPATH_LOOKUP=true
export HBASE_CLASSPATH='$HADOOP_CONF_DIR'
ENV
  fi
else
  backup "$HBASE_ENV_FILE"
  safe_append "$HBASE_ENV_FILE" <<ENV
# BDA-HBASE
export JAVA_HOME='$JAVA_HOME'
export HBASE_MANAGES_ZK=true
export HBASE_DISABLE_HADOOP_CLASSPATH_LOOKUP=true
export HBASE_CLASSPATH='$HADOOP_CONF_DIR'
ENV
fi
# Apply the fix to this process immediately (not only to future shells).
export HBASE_DISABLE_HADOOP_CLASSPATH_LOOKUP=true
export HBASE_CLASSPATH="$HADOOP_CONF_DIR"
FS="$("$HADOOP_HOME/bin/hdfs" getconf -confKey fs.defaultFS)"
[[ "$FS" == hdfs://* ]] || fail "An HDFS filesystem is required for this experiment; detected: $FS"
ROOTDIR="${FS%/}/bda-hbase-2.4.18"
# Read the actual XML values. Do not assume "has a rootdir" means "is configured correctly".
site_prop() {
  python3 - "$HBASE_HOME/conf/hbase-site.xml" "$1" <<'PYXML'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
    for prop in root.findall('property'):
        if prop.findtext('name') == sys.argv[2]:
            print((prop.findtext('value') or '').strip())
            break
except (FileNotFoundError, ET.ParseError):
    pass
PYXML
}
CONFIG_ROOT="$(site_prop 'hbase.rootdir')"
LAB_MANAGED=0
# An interrupted lab installation may have written the HDFS root but not
# its ZooKeeper settings. Only reconfigure that exact lab-owned root.
if [[ "$CONFIG_ROOT" == "$ROOTDIR" ]]; then
  old_parent="$(site_prop 'zookeeper.znode.parent')"
  old_quorum="$(site_prop 'hbase.zookeeper.quorum')"
  old_port="$(site_prop 'hbase.zookeeper.property.clientPort')"
  old_mode="$(site_prop 'hbase.cluster.distributed')"
  if [[ "$old_parent" != '/bda-hbase-2-4-18' || "$old_quorum" != localhost || "$old_port" != 2181 || "$old_mode" != true ]]; then
    backup "$HBASE_HOME/conf/hbase-site.xml"
    # Preserve the original ZooKeeper data directory if it is set. Never delete it.
    old_zkdir="$(site_prop 'hbase.zookeeper.property.dataDir')"
    [[ -n "$old_zkdir" ]] || old_zkdir="$ROOT/hbase-zk"
    mkdir -p "$old_zkdir"
    python3 - "$HBASE_HOME/conf/hbase-site.xml" "$ROOTDIR" "$old_zkdir" > "$ROOT/logs/hbase-site-fixed.xml" <<'PYXMLFIX'
import sys, xml.etree.ElementTree as ET
p, rootdir, zkdir = sys.argv[1:]
try:
    root = ET.parse(p).getroot()
except (FileNotFoundError, ET.ParseError):
    root = ET.Element('configuration')
settings = {
    'hbase.rootdir': rootdir,
    'hbase.cluster.distributed': 'true',
    'hbase.zookeeper.quorum': 'localhost',
    'hbase.zookeeper.property.clientPort': '2181',
    'hbase.zookeeper.property.dataDir': zkdir,
    'zookeeper.znode.parent': '/bda-hbase-2-4-18',
    'hbase.unsafe.stream.capability.enforce': 'false',
}
for name, val in settings.items():
    prop = next((x for x in root.findall('property') if x.findtext('name') == name), None)
    if prop is None:
        prop = ET.SubElement(root, 'property')
        ET.SubElement(prop, 'name').text = name
    v = prop.find('value')
    if v is None:
        v = ET.SubElement(prop, 'value')
    v.text = val
ET.indent(root, space='  ')
print('<?xml version="1.0"?>')
print(ET.tostring(root, encoding='unicode'))
PYXMLFIX
    safe_write "$HBASE_HOME/conf/hbase-site.xml" < "$ROOT/logs/hbase-site-fixed.xml"
  fi
fi
if [[ -z "$CONFIG_ROOT" ]]; then
  backup "$HBASE_HOME/conf/hbase-site.xml"
  mkdir -p "$ROOT/hbase-zk"
  safe_write "$HBASE_HOME/conf/hbase-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>hbase.rootdir</name><value>$ROOTDIR</value></property>
  <property><name>hbase.cluster.distributed</name><value>true</value></property>
  <property><name>hbase.zookeeper.quorum</name><value>localhost</value></property>
  <property><name>hbase.zookeeper.property.clientPort</name><value>2181</value></property>
  <property><name>hbase.zookeeper.property.dataDir</name><value>$ROOT/hbase-zk</value></property>
  <property><name>zookeeper.znode.parent</name><value>/bda-hbase-2-4-18</value></property>
  <property><name>hbase.unsafe.stream.capability.enforce</name><value>false</value></property>
</configuration>
XML
else
  note "Existing HBase configuration found: $CONFIG_ROOT (preserving it)."
fi
CONFIG_ROOT="$(site_prop 'hbase.rootdir')"
CONFIG_PARENT="$(site_prop 'zookeeper.znode.parent')"
CONFIG_QUORUM="$(site_prop 'hbase.zookeeper.quorum')"
CONFIG_PORT="$(site_prop 'hbase.zookeeper.property.clientPort')"
CONFIG_MODE="$(site_prop 'hbase.cluster.distributed')"
if [[ "$CONFIG_ROOT" == "$ROOTDIR" && "$CONFIG_PARENT" == '/bda-hbase-2-4-18' &&
      "$CONFIG_QUORUM" == 'localhost' && "$CONFIG_PORT" == '2181' && "$CONFIG_MODE" == 'true' ]]; then
  LAB_MANAGED=1
fi
# A running master using another config may register at /hbase/master instead.
# Never reset that cluster merely to make this client's znode appear.
# Do not start a second HBase master against an existing different cluster.
if "$JAVA_HOME/bin/jps" | grep -qE '[[:space:]]HMaster($|[[:space:]])'; then
  note 'HMaster is already running; checking via this HBase client.'
else
  note 'Starting HBase services.'
  "$HBASE_HOME/bin/start-hbase.sh" || warn 'Initial HBase startup returned an error; checking daemon status.'
fi
# A RegionServer can fail independently of the master on smaller Ubuntu VMs.
if "$JAVA_HOME/bin/jps" | grep -q HMaster && ! "$JAVA_HOME/bin/jps" | grep -q HRegionServer; then
  warn 'HMaster is running without a RegionServer; starting the missing RegionServer.'
  timeout --foreground -k 5s 45 "$HBASE_HOME/bin/hbase-daemon.sh" start regionserver || true
fi
note 'Waiting for an active HMaster in ZooKeeper and an online RegionServer.'
if ! bda_hbase_status_wait; then
  warn 'HBase Java processes exist, but no active master was registered in ZooKeeper.'
  if (( LAB_MANAGED )); then
    bda_hbase_owned_processes || { bda_hbase_master_logs; fail 'HBase daemons may belong to another installation; no restart attempted.'; }
    note 'Restarting only the HBase instance managed by this BDA lab. Preserving HDFS and ZooKeeper data.'
    if ! timeout --foreground -k 5s 70 "$HBASE_HOME/bin/stop-hbase.sh"; then
      warn 'The normal HBase stop command did not complete successfully.'
    fi
    for i in {1..20}; do
      if ! "$JAVA_HOME/bin/jps" | grep -Eq 'HMaster|HRegionServer'; then break; fi
      sleep 2
    done
    if "$JAVA_HOME/bin/jps" | grep -Eq 'HMaster|HRegionServer'; then
      bda_hbase_master_logs
      fail 'HBase did not shut down cleanly; leaving the existing processes and data intact.'
    fi
    "$HBASE_HOME/bin/start-hbase.sh" || warn 'Restart reported a warning; checking actual master registration.'
    if ! bda_hbase_status_wait; then
      bda_hbase_master_logs
      fail 'HMaster still is not registered. Check the master logs shown above for HDFS or ZooKeeper errors.'
    fi
  else
    bda_hbase_master_logs
    fail "Existing HBase uses another configuration ($CONFIG_ROOT, znode $CONFIG_PARENT); auto-restart is unsafe."
  fi
fi
if ! "$JAVA_HOME/bin/jps" | grep -q ThriftServer; then
  note 'Starting HBase Thrift server (port 9090).'
  "$HBASE_HOME/bin/hbase-daemon.sh" start thrift
fi
for i in {1..25}; do
  "$JAVA_HOME/bin/jps" | grep -q ThriftServer && break
  sleep 2
done
"$JAVA_HOME/bin/jps" | grep -q ThriftServer || fail 'Thrift did not start; inspect HBase logs/port 9090.'
"$JAVA_HOME/bin/jps"
note 'HBASE READY. New terminal: hbase shell; UI http://localhost:16010; Thrift TCP 9090'

}

bda_init_lab 'EXPERIMENT 6 — HBase table operations, Thrift'
bda_setup_exp6
bda_step 'hbase version' hbase version
bda_step 'jps' jps
# Execute the PDF-style HBase commands inside ONE real, interactive hbase shell.
# The PTY shows HBase's own prompt/output. Commands are typed character by
# character, with a silent Enter confirmation before each command is executed.
# The table and values are generic sample data, not copied from the PDF.
bda_hbase_console() {
  BDA_HBASE_CONSOLE_BIN="$HBASE_HOME/bin/hbase" \
  BDA_HBASE_CONSOLE_DELAY="${BDA_TYPING_DELAY:-0.04}" \
  BDA_HBASE_CONSOLE_AUTO="${BDA_AUTO:-0}" \
  BDA_HBASE_CONSOLE_LOG="$ROOT/logs/hbase-console-last.log" \
  python3 - <<'PYHBASE'
import errno
import os
import pty
import re
import select
import signal
import sys
import termios
import time

# HBase operations follow the order of the lab experiment:
# create, list, describe, put, get, scan, count, delete, deleteall,
# disable, enable, disable, drop. Only the sample table/data differ.
table = 'student_records'
family = 'info'
commands = [
    f"create '{table}', '{family}' unless exists('{table}')",
    f"enable '{table}' if is_disabled('{table}')",  # rerun recovery
    'list',
    f"describe '{table}'",
    f"put '{table}', 'r1', '{family}:name', 'Alice'",
    f"put '{table}', 'r1', '{family}:dept', 'CS'",
    f"put '{table}', 'r2', '{family}:name', 'Bob'",
    f"get '{table}', 'r1'",
    f"get '{table}', 'r1', {{COLUMN => '{family}:name'}}",
    f"scan '{table}'",
    f"count '{table}'",
    f"delete '{table}', 'r1', '{family}:dept'",
    f"deleteall '{table}', 'r2'",
    f"scan '{table}'",
    f"disable '{table}' if is_enabled('{table}')",
    f"enable '{table}' if is_disabled('{table}')",
    f"disable '{table}' if is_enabled('{table}')",
    f"drop '{table}' if exists('{table}')",
    'list',
]

binary = os.environ['BDA_HBASE_CONSOLE_BIN']
automatic = os.environ.get('BDA_HBASE_CONSOLE_AUTO') == '1'
delay = float(os.environ.get('BDA_HBASE_CONSOLE_DELAY', '0.04'))
log_path = os.environ.get('BDA_HBASE_CONSOLE_LOG')
# Handle the prompt formats used by recent HBase versions.
PROMPT = re.compile(rb'(?:hbase(?:\(main\))?:[0-9]+:[0-9]+)>[ \t]*$')
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
FAILURE = re.compile(rb'(?im)(?:^|[\r\n])\s*(?:ERROR\b|Unhandled Java exception|SyntaxError\b|NoMethodError\b|NameError\b|ArgumentError\b)|(?:KeeperException|MasterNotRunningException|TableNotFoundException|PleaseHoldException)')

pid, master = pty.fork()
if pid == 0:
    os.execv(binary, [binary, 'shell'])

log = open(log_path, 'wb', buffering=0) if log_path else None


def show(data):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    if log:
        log.write(data)


def take_available(timeout=0):
    readable, _, _ = select.select([master], [], [], timeout)
    if not readable:
        return b''
    try:
        data = os.read(master, 65536)
    except OSError as error:
        if error.errno == errno.EIO:
            return b''
        raise
    if data:
        show(data)
    return data


def wait_for_prompt(timeout):
    deadline = time.monotonic() + timeout
    accumulated = bytearray()
    while time.monotonic() < deadline:
        piece = take_available(min(1., max(0., deadline - time.monotonic())))
        if not piece:
            # distinguish a closed CLI from an idle CLI
            gone, _ = os.waitpid(pid, os.WNOHANG)
            if gone:
                raise RuntimeError('HBase console terminated unexpectedly')
            continue
        accumulated.extend(piece)
        if len(accumulated) > 262144:
            del accumulated[:-262144]
        plain = ANSI.sub(b'', bytes(accumulated)).replace(b'\r', b'')
        if PROMPT.search(plain):
            return plain
    raise TimeoutError('HBase did not return to its prompt within the configured timeout')


def silent_enter():
    if automatic:
        return
    try:
        tty_fd = os.open('/dev/tty', os.O_RDONLY)
    except OSError:
        return
    saved = termios.tcgetattr(tty_fd)
    try:
        attrs = saved.copy()
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(tty_fd, termios.TCSANOW, attrs)
        ready, _, _ = select.select([tty_fd], [], [], float(os.environ.get('BDA_ENTER_TIMEOUT', '3')))
        if not ready:
            return
        typed = os.read(tty_fd, 4096)
        if typed.strip().lower() == b'q':
            raise KeyboardInterrupt
        if typed.strip():
            raise ValueError('Press Enter to run the displayed HBase command')
    finally:
        termios.tcsetattr(tty_fd, termios.TCSANOW, saved)
        os.close(tty_fd)


def submit(statement):
    # Write one character at a time to the actual HBase console's PTY.
    # Flush the PTY echo as characters arrive, rather than after the line.
    for character in statement.encode('utf-8'):
        os.write(master, bytes([character]))
        take_available(0.004)
        if not automatic and delay > 0:
            time.sleep(delay)
    os.write(master, b'\r')
    response = wait_for_prompt(360)
    if FAILURE.search(response):
        raise RuntimeError('The HBase console returned an error; subsequent table operations were stopped')


def close_console():
    try:
        os.write(master, b'exit\r')
    except OSError:
        return
    end = time.monotonic() + 15
    while time.monotonic() < end:
        child, _ = os.waitpid(pid, os.WNOHANG)
        if child:
            return
        take_available(0.25)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


try:
    wait_for_prompt(240)
    for command in commands:
        silent_enter()
        submit(command)
    close_console()
except (KeyboardInterrupt, EOFError):
    close_console()
    sys.exit(130)
except (RuntimeError, TimeoutError, ValueError) as exc:
    print(f'\n[ERROR] {exc}', file=sys.stderr)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    sys.exit(1)
finally:
    if log:
        log.close()
    os.close(master)
PYHBASE
}

bda_step 'hbase shell' bda_hbase_console
# Keep HBase running for other experiments. No stop-hbase.sh here.
bda_finished
