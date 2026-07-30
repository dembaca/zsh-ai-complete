#!/usr/bin/env bash
# Tests for lib/safety.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/safety.sh
source "$ROOT/lib/safety.sh"

pass=0
fail=0

expect_warn() {
  local cmd="$1"
  local label
  set +e
  label="$(ai_complete_safety_check "$cmd")"
  local rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    echo "PASS warn: $cmd ($label)"
    pass=$((pass + 1))
  else
    echo "FAIL expected warn: $cmd (rc=$rc)"
    fail=$((fail + 1))
  fi
}

expect_clean() {
  local cmd="$1"
  set +e
  ai_complete_safety_check "$cmd" >/dev/null
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "PASS clean: $cmd"
    pass=$((pass + 1))
  else
    echo "FAIL expected clean: $cmd (rc=$rc)"
    fail=$((fail + 1))
  fi
}

expect_warn 'rm -rf /'
expect_warn 'rm -rf ~'
expect_warn 'rm -rf $HOME'
expect_warn 'rm -fr /'
expect_warn 'dd if=/dev/zero of=/dev/disk0'
expect_warn 'mkfs.ext4 /dev/sdb1'
expect_warn 'git push --force origin main'
expect_warn 'git push -f origin master'
expect_warn 'chmod -R 777 /tmp/proj'
expect_warn 'chmod 777 /tmp/x'
expect_warn ':(){ :|:& };:'
expect_warn 'cat foo > /dev/sda'
expect_warn 'diskutil eraseDisk JHFS+ Untitled disk2'

expect_clean 'ls -la'
expect_clean 'rm file.txt'
expect_clean 'rm -rf ./build'
expect_clean 'git push origin main'
expect_clean 'git push --force origin feature-branch'
expect_warn 'dd if=input.img of=output.img'
expect_clean 'find . -name "*.log" -mtime +7 -delete'
expect_clean 'chmod 755 script.sh'

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
