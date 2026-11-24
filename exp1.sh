#!/usr/bin/env bash
# BDA practical experiments. Run as a regular Ubuntu user, not sudo.
# Part of a seven-file lab bundle. Other scripts load functions from exp1.sh.
if [[ "${BDA_LIBRARY_LOADED:-0}" == 1 ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
fi
BDA_LIBRARY_LOADED=1
set -Eeuo pipefail
[[ $EUID -ne 0 ]] || { echo '[ERROR] Run as your normal Ubuntu user; scripts call sudo only when required.' >&2; exit 1; }
ROOT="$HOME/.bda-lab-setup"
TOOLS="$HOME/bda-lab-tools"
CACHE="$ROOT/downloads"
ENV_DIR="$HOME/.bda-lab-env.d"
mkdir -p "$ROOT/backups" "$ROOT/logs" "$CACHE" "$TOOLS" "$ENV_DIR"
APT_UPDATED=0
note() { printf "%s | %s\n" "$(date +%F_%T)" "$*" >> "$ROOT/logs/setup-events.log"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_sudo() { if (( EUID==0 )); then "$@"; else command -v sudo >/dev/null || fail 'sudo not installed'; sudo "$@"; fi; }
APT_UPDATED=0
install_pkgs() {
  command -v apt-get >/dev/null || fail 'Automatic packages require Ubuntu/Debian apt-get.'
  if (( ! APT_UPDATED )); then need_sudo apt-get update; APT_UPDATED=1; fi
  need_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || install_pkgs "$2"; command -v "$1" >/dev/null 2>&1 || fail "Cannot install $1"; }
base_tools() {
  require_cmd wget wget
  require_cmd tar tar
  require_cmd curl curl
  require_cmd python3 python3
}
valid_java8() {
  [[ -n "${1:-}" && -x "$1/bin/java" && -x "$1/bin/javac" ]] || return 1
  "$1/bin/java" -version 2>&1 | head -1 | grep -Eq 'version "(1\.8\.|8[.+])'
}
find_java8() {
  local x
  for x in "${BDA_JAVA8_HOME:-}" "${JAVA_HOME:-}" \
    /usr/lib/jvm/java-8-openjdk-* /usr/lib/jvm/temurin-8-jdk-* \
    "$HOME"/.sdkman/candidates/java/8* "$HOME/.local/opt/temurin8-hadoop-lab" "$TOOLS/temurin8"; do
    [[ -n "$x" ]] || continue
    if valid_java8 "$x"; then JAVA_HOME="$(readlink -f "$x")"; export JAVA_HOME; return 0; fi
  done
  if command -v java >/dev/null 2>&1; then
    x="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    if valid_java8 "$x"; then JAVA_HOME="$x"; export JAVA_HOME; return 0; fi
  fi
  return 1
}
# Prefer an installed Java 8 JDK; use an official Temurin binary on Ubuntu
# releases where apt no longer publishes openjdk-8-jdk.
ensure_java8() {
  if ! find_java8; then
    note 'Java 8 JDK missing; trying the Ubuntu package.'
    if command -v apt-cache >/dev/null && apt-cache show openjdk-8-jdk 2>/dev/null | grep -q '^Package: '; then
      install_pkgs openjdk-8-jdk || warn 'Ubuntu Java 8 package failed; trying Temurin download.'
    fi
    if ! find_java8; then
      base_tools
      local arch tarball tmp jhome java_exe
      case "$(uname -m)" in
        x86_64|amd64) arch=x64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fail 'Java 8 automatic download supports Ubuntu x86_64 and ARM64 only. Set BDA_JAVA8_HOME.' ;;
      esac
      tarball="$CACHE/temurin8-$arch-jdk.tar.gz"
      if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        note 'Downloading official Eclipse Temurin Java 8 JDK.'
        curl -fL --retry 3 --connect-timeout 20 --max-time 600 \
          -o "$tarball.part" \
          "https://api.adoptium.net/v3/binary/latest/8/ga/linux/$arch/jdk/hotspot/normal/eclipse" \
          || fail 'Temurin 8 download failed. Check internet or set BDA_JAVA8_HOME.'
        tar -tzf "$tarball.part" >/dev/null 2>&1 || fail 'Temurin archive is incomplete or corrupt.'
        mv "$tarball.part" "$tarball"
      fi
      tmp="$(mktemp -d "$TOOLS/.java8.XXXXXXXX")"
      tar -xzf "$tarball" -C "$tmp" || fail 'Unable to unpack Temurin JDK.'
      java_exe="$(find "$tmp" -maxdepth 3 -type f -path '*/bin/java' -print -quit)"
      [[ -n "$java_exe" ]] || fail 'Temurin archive did not contain bin/java.'
      jhome="${java_exe%/bin/java}"
      if [[ -e "$TOOLS/temurin8" ]]; then
        mv "$TOOLS/temurin8" "$ROOT/backups/temurin8-incomplete.$(date +%Y%m%d%H%M%S).$$"
      fi
      mv "$jhome" "$TOOLS/temurin8"
      rm -rf "$tmp"
    fi
  fi
  find_java8 || fail 'Java 8 JDK not found. Set BDA_JAVA8_HOME to a working Java 8 JDK and retry.'
  export PATH="$JAVA_HOME/bin:$PATH"
  note "Java 8 ready: $JAVA_HOME"
}
# Downloads are validated as genuine gzip/tar archives; corrupt downloads are retried.
archive_download() {
  local dest="$1" url; shift
  if [[ -s "$dest" ]] && tar -tzf "$dest" >/dev/null 2>&1; then note "Cached archive: $dest"; return 0; fi
  rm -f "$dest" "$dest.part"
  for url in "$@"; do
    note "Download: $url"
    if wget -c --tries=3 --timeout=35 -O "$dest.part" "$url"; then
      if tar -tzf "$dest.part" >/dev/null 2>&1; then mv "$dest.part" "$dest"; return 0; fi
      warn "Archive verification failed: $url"
    else
      warn "Mirror unavailable: $url"
    fi
    rm -f "$dest.part"   # Never resume bytes from a different mirror.
  done
  fail "All download sources failed for $(basename "$dest")."
}
archive_install() {
  local arc="$1" dirname="$2" destination="$3" tmp
  [[ ! -e "$destination" ]] || fail "Existing directory cannot be replaced safely: $destination"
  tmp="$(mktemp -d "$TOOLS/.extract.XXXXXXXX")"
  if ! tar -xzf "$arc" -C "$tmp"; then rm -rf "$tmp"; fail "Cannot extract $arc"; fi
  [[ -d "$tmp/$dirname" ]] || { rm -rf "$tmp"; fail "Wrong archive layout for $dirname"; }
  mv "$tmp/$dirname" "$destination"
  rmdir "$tmp"
}
backup() {
  [[ -e "$1" ]] || return 0
  local dst="$ROOT/backups/$(basename "$1").$(date +%Y%m%d-%H%M%S).$$"
  cp -a "$1" "$dst"; note "Config backup: $dst"
}
# Write configuration using sudo only if a previous system install is root-owned.
safe_write() {
  local path="$1" tmp
  tmp="$(mktemp "$ROOT/config.XXXXXXXX")"
  cat > "$tmp"
  if [[ -w "$path" || ( ! -e "$path" && -w "$(dirname "$path")" ) ]]; then
    install -m 0644 "$tmp" "$path"
  else
    need_sudo install -m 0644 "$tmp" "$path"
  fi
  rm -f "$tmp"
}
safe_append() {
  local path="$1" tmp
  tmp="$(mktemp "$ROOT/append.XXXXXXXX")"
  cat > "$tmp"
  if [[ -w "$path" || ( ! -e "$path" && -w "$(dirname "$path")" ) ]]; then
    cat "$tmp" >> "$path"
  else
    need_sudo tee -a "$path" < "$tmp" >/dev/null
  fi
  rm -f "$tmp"
}
profile_init() {
  local line='for _bda in "$HOME"/.bda-lab-env.d/*.sh; do [ -f "$_bda" ] && . "$_bda"; done; unset _bda'
  touch "$HOME/.bashrc"
  grep -Fxq "$line" "$HOME/.bashrc" || printf '\n# BDA lab setup (Java / Hadoop / Hive / HBase / Sqoop)\n%s\n' "$line" >> "$HOME/.bashrc"
}
write_profile() {
  local name="$1"; shift
  profile_init
  printf '%s\n' "$@" > "$ENV_DIR/$name"
  # shellcheck disable=SC1090
  . "$ENV_DIR/$name"
}
find_hadoop() {
  local d
  for d in "${BDA_HADOOP_HOME:-}" "${HADOOP_HOME:-}" "$HOME/hadoop-3.2.3" "$TOOLS/hadoop-3.2.3" /usr/local/hadoop; do
    [[ -n "$d" && -x "$d/bin/hdfs" && -f "$d/share/hadoop/common/hadoop-common-3.2.3.jar" ]] && { HADOOP_HOME="$(readlink -f "$d")"; export HADOOP_HOME; return 0; }
  done
  if command -v hadoop >/dev/null 2>&1; then
    d="$(dirname "$(dirname "$(readlink -f "$(command -v hadoop)")")")"
    [[ -f "$d/share/hadoop/common/hadoop-common-3.2.3.jar" ]] && { HADOOP_HOME="$d"; export HADOOP_HOME; return 0; }
  fi
  return 1
}
load_hadoop() {
  [[ -f "$ENV_DIR/10_hadoop.sh" ]] && . "$ENV_DIR/10_hadoop.sh"
  if ! find_hadoop; then
    note 'Hadoop 3.2.3 not detected: installing and configuring automatically.'
    bda_setup_hadoop
  else
    ensure_java8
    export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"
    export HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME"
    export HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"
    export HADOOP_STREAMING="$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.2.3.jar"
    export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
  fi
}
ensure_hdfs() {
  if ! timeout 18 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1; then
    note 'HDFS not responding; starting existing Hadoop services.'
    "$HADOOP_HOME/sbin/start-dfs.sh"
  fi
  local i
  for i in {1..30}; do
    timeout 10 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail "HDFS is not ready. Check $HADOOP_HOME/logs and rerun ./exp1.sh."
}


bda_setup_hadoop() {
note 'HADOOP 3.2.3: install, configure, start, verify'
base_tools
require_cmd ssh openssh-client
require_cmd ssh-keygen openssh-client
require_cmd sshd openssh-server
ensure_java8
if find_hadoop; then
  note "Using existing Hadoop: $HADOOP_HOME"
else
  HADOOP_HOME="$HOME/hadoop-3.2.3"
  if [[ -e "$HADOOP_HOME" ]]; then
    # Never overwrite an unknown Hadoop install; relocate an incomplete
    # extracted directory in the lab user's home, retaining its bytes.
    [[ "$HADOOP_HOME" == "$HOME/hadoop-3.2.3" ]] || fail "An unrecognized Hadoop install exists at $HADOOP_HOME."
    backup_dir="$ROOT/backups/hadoop-incomplete.$(date +%Y%m%d%H%M%S).$$"
    note "Moving incomplete Hadoop installation to $backup_dir"
    mv "$HADOOP_HOME" "$backup_dir"
  fi
  ARC="$CACHE/hadoop-3.2.3.tar.gz"
  archive_download "$ARC" \
    'https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz' \
    'https://archive.apache.org/dist/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz'
  archive_install "$ARC" hadoop-3.2.3 "$HADOOP_HOME"
fi
[[ -x "$HADOOP_HOME/bin/hadoop" ]] || fail 'Hadoop installation files are incomplete.'
export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop" HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME" HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
write_profile 10_hadoop.sh \
  "export JAVA_HOME='$JAVA_HOME'" \
  "export HADOOP_HOME='$HADOOP_HOME'" \
  'export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"' \
  'export HADOOP_MAPRED_HOME="$HADOOP_HOME" HADOOP_COMMON_HOME="$HADOOP_HOME" HADOOP_HDFS_HOME="$HADOOP_HOME" HADOOP_YARN_HOME="$HADOOP_HOME"' \
  'export HADOOP_STREAMING="$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.2.3.jar"' \
  'export PDSH_RCMD_TYPE=ssh' \
  'export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"'
# Keep existing active HDFS configs. Never replace a running cluster's settings.
FSDIR="$HOME/bda-hdfs-data"
FS="$("$HADOOP_HOME/bin/hdfs" getconf -confKey fs.defaultFS 2>/dev/null || true)"
if [[ "$FS" == hdfs://* ]]; then
  note "Existing HDFS configuration detected: $FS (preserving configurations and metadata)."
  MANAGED=0
  # A previous interrupted run may have written the lab configuration before
  # reaching its one-time format. Recover ONLY the matching lab storage paths.
  NAMEDIR="$("$HADOOP_HOME/bin/hdfs" getconf -confKey dfs.namenode.name.dir 2>/dev/null || true)"
  DATADIR="$("$HADOOP_HOME/bin/hdfs" getconf -confKey dfs.datanode.data.dir 2>/dev/null || true)"
  if [[ "$FS" == 'hdfs://localhost:9000' && "$NAMEDIR" == *"$FSDIR/name"* && "$DATADIR" == *"$FSDIR/data"* ]]; then
    MANAGED=1
    note 'Recognized lab-managed HDFS directories; checking first-time formatting.'
  fi
else
  if "$JAVA_HOME/bin/jps" -l | grep -Eq 'org\.apache\.hadoop\.hdfs\.server\.namenode\.NameNode'; then
    fail 'NameNode is already running with a different configuration; refusing to reconfigure.'
  fi
  MANAGED=1
  mkdir -p "$FSDIR/name" "$FSDIR/data"
  for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do backup "$HADOOP_CONF_DIR/$f"; done
  safe_write "$HADOOP_CONF_DIR/core-site.xml" <<'XML'
<?xml version="1.0"?>
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/hdfs-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>dfs.replication</name><value>1</value></property>
  <property><name>dfs.namenode.name.dir</name><value>file://$FSDIR/name</value></property>
  <property><name>dfs.datanode.data.dir</name><value>file://$FSDIR/data</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/mapred-site.xml" <<XML
<?xml version="1.0"?>
<configuration>
  <property><name>mapreduce.framework.name</name><value>yarn</value></property>
  <property><name>yarn.app.mapreduce.am.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.map.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.reduce.env</name><value>HADOOP_MAPRED_HOME=$HADOOP_HOME</value></property>
  <property><name>mapreduce.map.memory.mb</name><value>512</value></property>
  <property><name>mapreduce.reduce.memory.mb</name><value>512</value></property>
</configuration>
XML
  safe_write "$HADOOP_CONF_DIR/yarn-site.xml" <<'XML'
<?xml version="1.0"?>
<configuration>
  <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
  <property><name>yarn.nodemanager.vmem-check-enabled</name><value>false</value></property>
  <property><name>yarn.nodemanager.resource.memory-mb</name><value>2048</value></property>
  <property><name>yarn.scheduler.minimum-allocation-mb</name><value>128</value></property>
  <property><name>yarn.nodemanager.env-whitelist</name><value>JAVA_HOME,HADOOP_HOME,HADOOP_MAPRED_HOME,HADOOP_HDFS_HOME,HADOOP_COMMON_HOME,HADOOP_YARN_HOME,HADOOP_CONF_DIR,PATH,LANG,TZ,CLASSPATH_PREPEND_DISTCACHE</value></property>
</configuration>
XML
fi
# Set JAVA_HOME in Hadoop's daemon environment only once (last export takes precedence).
if ! grep -q '^# BDA-JAVA8' "$HADOOP_CONF_DIR/hadoop-env.sh"; then
  backup "$HADOOP_CONF_DIR/hadoop-env.sh"
  printf '\n# BDA-JAVA8\nexport JAVA_HOME=%q\n' "$JAVA_HOME" | safe_append "$HADOOP_CONF_DIR/hadoop-env.sh"
fi
# Prepare local SSH; do not overwrite an existing identity.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then PUB="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then PUB="$HOME/.ssh/id_rsa.pub"
else ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"; PUB="$HOME/.ssh/id_ed25519.pub"; fi
PUBTEXT="$(cat "$PUB")"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
grep -Fxq "$PUBTEXT" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$PUBTEXT" >> "$HOME/.ssh/authorized_keys"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  need_sudo systemctl enable --now ssh || need_sudo service ssh start
else need_sudo service ssh start; fi
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 localhost true || fail 'Passwordless localhost SSH failed.'
# Format only an empty NameNode directory created by this installer.
if (( MANAGED )); then
  if [[ ! -f "$FSDIR/name/current/VERSION" ]]; then
    [[ -z "$(ls -A "$FSDIR/name")" ]] || fail 'NameNode directory is nonempty and not recognized; will not format.'
    note 'First-time NameNode format (only once).'
    "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
  else note 'Existing NameNode metadata found; skipping format.'; fi
fi
if ! timeout 15 "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1; then
  note 'Starting HDFS'; "$HADOOP_HOME/sbin/start-dfs.sh"
fi
ensure_hdfs
if ! "$JAVA_HOME/bin/jps" | grep -q 'ResourceManager'; then note 'Starting YARN'; "$HADOOP_HOME/sbin/start-yarn.sh"; fi
for i in {1..30}; do
  "$JAVA_HOME/bin/jps" | grep -q ResourceManager && "$JAVA_HOME/bin/jps" | grep -q NodeManager && break
  sleep 2
done
"$JAVA_HOME/bin/jps" | grep -q ResourceManager || fail 'YARN ResourceManager did not start.'
"$JAVA_HOME/bin/jps" | grep -q NodeManager || fail 'YARN NodeManager did not start.'
"$HADOOP_HOME/bin/hadoop" version | head -n 2
"$JAVA_HOME/bin/jps"
"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p "/user/$(id -un)"
note 'HADOOP READY. HDFS UI: http://localhost:9870 | YARN UI: http://localhost:8088'
note 'New terminal: hadoop version; jps; hadoop fs -ls /'

}

# Hadoop checks are cheap on repeat runs; new installs are managed by exp1.sh.
bda_ready_hadoop() {
  load_hadoop
  local fs
  fs="$(hdfs getconf -confKey fs.defaultFS 2>/dev/null || true)"
  if [[ "$fs" != hdfs://* ]]; then
    note 'Hadoop found but HDFS is not configured: configuring the single-node lab.'
    bda_setup_hadoop
  fi
  if ! timeout 20 hdfs dfs -ls / >/dev/null 2>&1; then
    note 'HDFS unavailable: starting services / checking configuration.'
    if [[ "$HADOOP_CONF_DIR" == "$HADOOP_HOME/etc/hadoop" ]] && ! find "$HOME/bda-hdfs-data/name" -name VERSION -print -quit 2>/dev/null | grep -q .; then
      # A configured but unformatted cluster may contain user data elsewhere; never auto-format it.
      warn 'No managed NameNode VERSION marker found. Will not reformat an unknown cluster.'
    fi
    "$HADOOP_HOME/sbin/start-dfs.sh" || warn 'HDFS startup returned a warning; checking actual state.'
  fi
  ensure_hdfs
}
bda_ready_yarn() {
  if ! "$JAVA_HOME/bin/jps" | grep -q ResourceManager || ! "$JAVA_HOME/bin/jps" | grep -q NodeManager; then
    note 'Starting YARN...'
    "$HADOOP_HOME/sbin/start-yarn.sh"
  fi
  local i
  for i in {1..30}; do
    if "$JAVA_HOME/bin/jps" | grep -q ResourceManager && "$JAVA_HOME/bin/jps" | grep -q NodeManager; then return 0; fi
    sleep 2
  done
  fail "YARN daemons not ready: inspect $HADOOP_HOME/logs."
}
bda_init_lab() {
  BDA_HOME="$HOME/bda-exp-work"
  BDA_HDFS_ROOT="/user/$(id -un)/bda_experiments"
  mkdir -p "$BDA_HOME"
  export BDA_HOME BDA_HDFS_ROOT
  BDA_STEPS=0
  BDA_DELAY="${BDA_TYPING_DELAY:-0.04}"
}
# Only retry steps that cannot duplicate or partially commit lab data.
bda_retry_is_safe() {
  case "$1" in
    *'sqoop import'*|*'sqoop export'*|*'INSERT INTO'*|*'insert into'*|*"put '"*|*'CREATE TABLE'*|*'DELETE FROM'*) return 1 ;;
    *) return 0 ;;
  esac
}
bda_attempt_repair() {
  local shown="$1"
  note "Diagnosing failed command: $shown"
  case "$shown" in
    hadoop\ *|hdfs\ *|jps*) bda_ready_hadoop; bda_ready_yarn ;;
    hive\ *)
      bda_ready_hadoop; bda_ready_yarn
      if declare -F bda_setup_exp5 >/dev/null; then bda_setup_exp5; else return 1; fi ;;
    *'hbase shell'*|hbase\ *)
      bda_ready_hadoop
      if declare -F bda_setup_exp6 >/dev/null; then bda_setup_exp6; else return 1; fi ;;
    sqoop\ *)
      bda_ready_hadoop; bda_ready_yarn
      if declare -F bda_setup_exp7 >/dev/null; then bda_setup_exp7; else return 1; fi ;;
    *) return 1 ;;
  esac
}
# The command shown is a demonstration; actual execution is passed as argv,
# never eval'ed. The program's actual stdout and stderr appear unchanged.
bda_step() {
  local shown="$1"; shift
  BDA_STEPS=$((BDA_STEPS+1))
  printf '\n'
  local promptdir="${PWD/#$HOME/\~}" i answer result
  if [[ -t 1 ]]; then
    printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m\$ ' "$(id -un)" "$(hostname -s)" "$promptdir"
  else
    printf '%s@%s:%s$ ' "$(id -un)" "$(hostname -s)" "$promptdir"
  fi
  if [[ -t 1 && "${BDA_AUTO:-0}" != 1 && "$BDA_DELAY" != 0 ]]; then
    for ((i=0; i<${#shown}; i++)); do
      printf '%s' "${shown:i:1}"
      sleep "$BDA_DELAY"
    done
  else
    printf '%s' "$shown"
  fi
  if [[ "${BDA_AUTO:-0}" != 1 && -t 0 ]]; then
    # A blank line executes now; no input executes automatically after 3 seconds.
    # /dev/tty may be unavailable for piped/non-interactive callers.
    local enter_rc=0
    if IFS= read -rs -t "${BDA_ENTER_TIMEOUT:-3}" answer < /dev/tty; then
      :
    else
      enter_rc=$?
      case "$enter_rc" in
        142|1) answer='' ;; # timeout (or EOF): proceed automatically
        *) fail 'Terminal input could not be read.' ;;
      esac
    fi
    printf '\n'
    case "$answer" in
      '') ;;
      q|Q) exit 0 ;;
      *) fail 'Only Enter or q is accepted. No command was executed.' ;;
    esac
  fi
  if "$@"; then
    return 0
  else
    result=$?
    warn "Command failed (exit $result): $shown"
    if bda_retry_is_safe "$shown" && bda_attempt_repair "$shown"; then
      note 'A repair was applied. Retrying this safe command once.'
      if "$@"; then return 0; fi
    fi
    fail 'Automatic recovery was insufficient, or retry could duplicate data. See the real command error above; existing unrelated data was left alone.'
  fi
}
bda_shell() { local shown="$1" command="$2"; bda_step "$shown" bash -euo pipefail -c "$command"; }
bda_finished() { :; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # EXPERIMENT 1: Setup + modes / files / daemon checks from the uploaded manual.
  bda_init_lab 'EXPERIMENT 1 — Install/configure Hadoop and inspect its modes'
  bda_setup_hadoop
  [[ "${1:-}" == '--setup-only' ]] && exit 0
  bda_step 'java -version' java -version
  bda_step 'hadoop version' hadoop version
  bda_step 'hdfs getconf -confKey fs.defaultFS' hdfs getconf -confKey fs.defaultFS
  for cfg in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do
    bda_step "cat $HADOOP_CONF_DIR/$cfg" cat "$HADOOP_CONF_DIR/$cfg"
  done
  bda_step 'jps' jps
  bda_step 'hadoop fs -ls /' hadoop fs -ls /

  bda_finished
fi
