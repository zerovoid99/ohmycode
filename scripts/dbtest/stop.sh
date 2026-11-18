#!/bin/zsh
# Stops the servers scripts/dbtest/start.sh started and removes their folder.
#
#   scripts/dbtest/stop.sh <folder>    # the OMC_DBTEST_DIR it printed
#   scripts/dbtest/stop.sh             # every omc-dbtest.* folder in $TMPDIR
set -uo pipefail

PG_BIN=${OMC_PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}

say() { print -u2 -- "dbtest: $*" }

stop_one() {
  local dir=${1:A}
  [[ -d $dir && ${dir:t} == omc-dbtest.* ]] || { say "not a dbtest folder: $dir"; return 1 }
  if [[ -f $dir/pg/postmaster.pid ]]; then
    $PG_BIN/pg_ctl -D $dir/pg -m immediate -w -t 20 stop >/dev/null 2>&1 || true
  fi
  if [[ -f $dir/mysqld.pid ]]; then
    local pid=$(<$dir/mysqld.pid)
    kill $pid 2>/dev/null || true
    for i in {1..40}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
    kill -9 $pid 2>/dev/null || true
  fi
  # Anything still running out of the folder (a server that never wrote its pid file).
  local stray=$(pgrep -f -- "$dir" 2>/dev/null || true)
  if [[ -n $stray ]]; then
    kill -9 ${=stray} 2>/dev/null || true
  fi
  rm -rf -- $dir
  say "stopped and removed $dir"
}

if (( $# > 0 )); then
  for dir in "$@"; do stop_one $dir; done
else
  for dir in ${TMPDIR:-/tmp}/omc-dbtest.*(N/); do stop_one $dir; done
fi
