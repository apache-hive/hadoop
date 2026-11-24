#!/usr/bin/env bash
# Source functions from exp1.sh without executing experiment 1.
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SELF_DIR/exp1.sh" ]] || { echo 'Missing exp1.sh. Keep all seven scripts together.' >&2; exit 1; }
# shellcheck source=exp1.sh
source "$SELF_DIR/exp1.sh"
bda_setup_exp7() {
# 04 - Apache Sqoop 1.4.7 + MySQL: installation/configuration only.
note 'SQOOP 1.4.7: install Sqoop, MySQL, JDBC dependencies, verify connection'
base_tools
load_hadoop
ensure_hdfs
if ! command -v mysql >/dev/null 2>&1 || ! command -v mysqld >/dev/null 2>&1; then install_pkgs mysql-server; fi
if ! mysqladmin ping >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1; then
    need_sudo systemctl start mysql || need_sudo service mysql start
  else need_sudo service mysql start; fi
fi
mysqladmin ping >/dev/null 2>&1 || fail 'MySQL server did not start.'
need_sudo mysql -N -e 'SELECT 1;' >/dev/null || fail 'sudo mysql administrative login failed. Configure local MySQL admin account.'
SQOOP_HOME=''
for d in "${BDA_SQOOP_HOME:-}" "$HOME/sqoop-1.4.7.bin__hadoop-2.6.0" "$TOOLS/sqoop-1.4.7.bin__hadoop-2.6.0" /usr/local/sqoop; do
  if [[ -n "$d" && -x "$d/bin/sqoop" && -f "$d/sqoop-1.4.7.jar" ]]; then SQOOP_HOME="$(readlink -f "$d")"; break; fi
done
if [[ -z "$SQOOP_HOME" ]] && command -v sqoop >/dev/null 2>&1; then
  d="$(dirname "$(dirname "$(readlink -f "$(command -v sqoop)")")")"
  [[ -f "$d/sqoop-1.4.7.jar" ]] && SQOOP_HOME="$d"
fi
if [[ -z "$SQOOP_HOME" ]]; then
  SQOOP_HOME="$HOME/sqoop-1.4.7.bin__hadoop-2.6.0"
  if [[ -e "$SQOOP_HOME" ]]; then
    note 'Backing up incomplete Sqoop extraction before reinstalling.'
    mv "$SQOOP_HOME" "$ROOT/backups/sqoop-incomplete.$(date +%Y%m%d%H%M%S).$$"
  fi
  ARC="$CACHE/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz"
  archive_download "$ARC" \
    'https://archive.apache.org/dist/sqoop/1.4.7/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz'
  archive_install "$ARC" sqoop-1.4.7.bin__hadoop-2.6.0 "$SQOOP_HOME"
fi
export SQOOP_HOME PATH="$SQOOP_HOME/bin:$PATH"
write_profile 40_sqoop.sh "export SQOOP_HOME='$SQOOP_HOME'" 'export PATH="$SQOOP_HOME/bin:$PATH"'
if [[ ! -f "$SQOOP_HOME/conf/sqoop-env.sh" ]]; then
  if [[ -w "$SQOOP_HOME/conf" ]]; then cp "$SQOOP_HOME/conf/sqoop-env-template.sh" "$SQOOP_HOME/conf/sqoop-env.sh"; else need_sudo cp "$SQOOP_HOME/conf/sqoop-env-template.sh" "$SQOOP_HOME/conf/sqoop-env.sh"; fi
fi
if ! grep -q '^# BDA-SQOOP' "$SQOOP_HOME/conf/sqoop-env.sh"; then
  backup "$SQOOP_HOME/conf/sqoop-env.sh"
  safe_append "$SQOOP_HOME/conf/sqoop-env.sh" <<ENV
# BDA-SQOOP
export HADOOP_COMMON_HOME='$HADOOP_HOME'
export HADOOP_MAPRED_HOME='$HADOOP_HOME'
ENV
fi
[[ -x "$JAVA_HOME/bin/jar" ]] || fail "Java JDK jar utility missing; check JAVA_HOME."
JAR_DIR="$SQOOP_HOME/lib"
download_jar() {
  local file="$1" url="$2" dest="$JAR_DIR/$1"
  if [[ -s "$dest" ]] && jar tf "$dest" >/dev/null 2>&1; then return 0; fi
  [[ ! -e "$dest" ]] || backup "$dest"
  note "Downloading missing JDBC/commons dependency: $file"
  curl -fL --retry 3 --connect-timeout 20 --output "$CACHE/$file.part" "$url"
  jar tf "$CACHE/$file.part" >/dev/null 2>&1 || fail "Invalid JAR: $file"
  if [[ -w "$JAR_DIR" ]]; then install -m 0644 "$CACHE/$file.part" "$dest"; else need_sudo install -m 0644 "$CACHE/$file.part" "$dest"; fi
  rm -f "$CACHE/$file.part"
}
download_jar mysql-connector-j-8.0.33.jar \
  https://repo.maven.apache.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar
download_jar commons-lang-2.6.jar \
  https://repo.maven.apache.org/maven2/commons-lang/commons-lang/2.6/commons-lang-2.6.jar
# Dedicated Sqoop lab account. Reconcile an account created by a prior run,
# including its password and host-scoped privileges. Never alter other users.
DB='bda_exp7_company'
DB_USER='bda_sqoop_lab'
DB_PASS="${BDA_SQOOP_LAB_PASSWORD:-sqoop123}"
[[ "$DB_PASS" =~ ^[A-Za-z0-9_@%+=.-]{6,64}$ ]] || fail 'BDA_SQOOP_LAB_PASSWORD must contain 6-64 letters, digits, or safe punctuation.'

# Use MySQL 8.4 syntax: CREATE IF NOT EXISTS alone does not repair a stale
# password. ALTER USER updates only our explicitly named lab user.
need_sudo mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS bda_exp7_company;
CREATE USER IF NOT EXISTS 'bda_sqoop_lab'@'localhost' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'bda_sqoop_lab'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
ALTER USER 'bda_sqoop_lab'@'localhost' IDENTIFIED BY '$DB_PASS' ACCOUNT UNLOCK;
ALTER USER 'bda_sqoop_lab'@'127.0.0.1' IDENTIFIED BY '$DB_PASS' ACCOUNT UNLOCK;
GRANT ALL PRIVILEGES ON bda_exp7_company.* TO 'bda_sqoop_lab'@'localhost';
GRANT ALL PRIVILEGES ON bda_exp7_company.* TO 'bda_sqoop_lab'@'127.0.0.1';
SQL

# Test exactly the same host and credentials that the JDBC URL will use.
if ! MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h 127.0.0.1 -u "$DB_USER" \
  -N -e 'SELECT 1;' "$DB" >/dev/null 2>&1; then
  fail 'Lab MySQL TCP authentication failed after account repair. Check MySQL server logs and local account policy.'
fi

# Critical: Sqoop 1.4.7 includes a final newline in --password-file in the
# password. printf %s (not echo / printf %s\\n) prevents MySQL error 1045.
PASSWORD_FILE="$ROOT/sqoop/mysql-password.txt"
mkdir -p "$(dirname "$PASSWORD_FILE")"
(umask 077; printf '%s' "$DB_PASS" > "$PASSWORD_FILE")
chmod 600 "$PASSWORD_FILE"
[[ "$(wc -c < "$PASSWORD_FILE")" -eq "${#DB_PASS}" ]] || fail 'Password file contains unexpected extra bytes.'
export BDA_SQOOP_USER="$DB_USER"

"$SQOOP_HOME/bin/sqoop" version
CONNECT='jdbc:mysql://127.0.0.1:3306/bda_exp7_company?useSSL=false&allowPublicKeyRetrieval=true'
note 'Testing real MySQL JDBC authentication using the exact Sqoop password file.'
if ! timeout --foreground -k 5s 120 "$SQOOP_HOME/bin/sqoop" list-tables \
  --connect "$CONNECT" --username "$DB_USER" --password-file "file://$PASSWORD_FILE"; then
  fail 'Sqoop JDBC connection failed despite a valid MySQL TCP login. Check Java connector, MySQL logs, and Sqoop output above.'
fi
note "SQOOP READY. Database: $DB; user: $DB_USER."

}

bda_init_lab 'EXPERIMENT 7 — Sqoop MySQL <-> HDFS import/export'
bda_setup_exp7
bda_ready_yarn
WORK="$BDA_HOME/exp7"
mkdir -p "$WORK"
make_sql() {
  cat > "$WORK/init.sql" <<'SQL'
CREATE DATABASE IF NOT EXISTS bda_exp7_company;
USE bda_exp7_company;
CREATE TABLE IF NOT EXISTS employees (
  id INT PRIMARY KEY, name VARCHAR(50), department VARCHAR(50), salary INT);
CREATE TABLE IF NOT EXISTS employees_exported (
  id INT PRIMARY KEY, name VARCHAR(50), department VARCHAR(50), salary INT);
DELETE FROM employees;
INSERT INTO employees VALUES
  (1, 'Raj', 'IT', 50000),
  (2, 'Ram', 'Finance', 49000),
  (3, 'Ravi', 'HR', 45000);
DELETE FROM employees_exported;
SQL
}
bda_step 'cat > ~/bda-exp-work/exp7/init.sql <<SQL  # MySQL data' make_sql
run_sql() { need_sudo mysql < "$WORK/init.sql"; }
bda_step 'sudo mysql < ~/bda-exp-work/exp7/init.sql' run_sql
bda_step 'sudo mysql -e "SELECT * FROM bda_exp7_company.employees;"'   need_sudo mysql -e 'SELECT * FROM bda_exp7_company.employees;'
CONNECT='jdbc:mysql://127.0.0.1:3306/bda_exp7_company?useSSL=false&allowPublicKeyRetrieval=true'
PASS_FILE="$ROOT/sqoop/mysql-password.txt"
bda_step 'sqoop version' sqoop version
bda_step "sqoop list-tables --connect \"$CONNECT\" --username $BDA_SQOOP_USER --password-file file://$PASS_FILE"   sqoop list-tables --connect "$CONNECT" --username "$BDA_SQOOP_USER" --password-file "file://$PASS_FILE"
bda_step "sqoop import --connect \"$CONNECT\" --username $BDA_SQOOP_USER --password-file file://$PASS_FILE --table employees --target-dir $BDA_HDFS_ROOT/exp7/employees_data --delete-target-dir -m 1"   sqoop import --connect "$CONNECT" --username "$BDA_SQOOP_USER" --password-file "file://$PASS_FILE"   --table employees --target-dir "$BDA_HDFS_ROOT/exp7/employees_data" --delete-target-dir -m 1
bda_step "hadoop fs -ls $BDA_HDFS_ROOT/exp7/employees_data" hadoop fs -ls "$BDA_HDFS_ROOT/exp7/employees_data"
bda_step "hadoop fs -cat $BDA_HDFS_ROOT/exp7/employees_data/part-m-00000" hadoop fs -cat "$BDA_HDFS_ROOT/exp7/employees_data/part-m-00000"
bda_step "sqoop export --connect \"$CONNECT\" --username $BDA_SQOOP_USER --password-file file://$PASS_FILE --table employees_exported --export-dir $BDA_HDFS_ROOT/exp7/employees_data --input-fields-terminated-by , -m 1"   sqoop export --connect "$CONNECT" --username "$BDA_SQOOP_USER" --password-file "file://$PASS_FILE"   --table employees_exported --export-dir "$BDA_HDFS_ROOT/exp7/employees_data"   --input-fields-terminated-by ',' -m 1
bda_step 'sudo mysql -e "SELECT * FROM bda_exp7_company.employees_exported;"'   need_sudo mysql -e 'SELECT * FROM bda_exp7_company.employees_exported;'
verify_sqoop_transfer() {
  local source="$WORK/sqoop-source.tsv" exported="$WORK/sqoop-exported.tsv"
  need_sudo mysql -N -B -e 'SELECT id,name,department,salary FROM bda_exp7_company.employees ORDER BY id;' > "$source"
  need_sudo mysql -N -B -e 'SELECT id,name,department,salary FROM bda_exp7_company.employees_exported ORDER BY id;' > "$exported"
  [[ "$(wc -l < "$source")" -eq 3 ]] || fail 'Source table should have three sample records.'
  diff -u "$source" "$exported" || fail 'Sqoop export produced records different from the source.'
}
bda_step 'diff -u sqoop-source.tsv sqoop-exported.tsv # verify export' verify_sqoop_transfer
bda_finished
