#!/bin/bash
# Runs a command with a hard time limit and, when the limit is hit, collects what is needed
# to find out why the run hung *before* stopping it.
#
#   Scripts/run-with-deadline.sh <seconds> -- <command> [args...]
#
# The deadline only protects from losing hours to a run that never ends; it is not a fix for the
# hang. What makes a hang investigable is the evidence taken at the deadline, while the processes
# are still stuck: after they are killed, nothing of their state is left.
#
# Everything lands in one folder per run (default `.build/deadline-runs/<time>`, override with
# `RUN_DIR`), and the command sees that folder as `$RUN_DIR`, so a test run can write its result
# bundle there:
#
#   Scripts/run-with-deadline.sh 1800 -- sh -c 'xcodebuild test -scheme … \
#       -resultBundlePath "$RUN_DIR/result.xcresult"'
#
# Files in the folder:
#   output.log        the full, unfiltered output of the command
#   command.txt       the command, the deadline and the start time
#   exit-status.txt   how the run ended: `finished <code>` or `deadline <seconds>`
#   on-deadline/      only if the deadline was hit:
#     processes.txt     the whole process table, with the run's process group marked
#     unpaired-tests.txt  tests whose `started` line has no `passed`/`failed` pair in the output
#     simulators.txt    the booted simulators
#     sample-<pid>-<name>.txt  a stack sample of each stuck process (see DIAGNOSE_PATTERN)
#
# Environment:
#   RUN_DIR           the folder of this run
#   DIAGNOSE_PATTERN  extended regex of process names to sample in addition to the run's own
#                     process group (default: the test runner, test hosts and the demo apps)
#   SAMPLE_SECONDS    length of one stack sample (default 3)
#   KILL_GRACE        seconds between the polite stop and the forced one (default 10)
#
# Exit status: the command's own, or 124 when the deadline stopped it.

set -u

if [ $# -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: $0 <seconds> -- <command> [args...]" >&2
  exit 2
fi

deadline=$1
shift 2

case $deadline in
  '' | *[!0-9]*) echo "deadline must be a whole number of seconds: $deadline" >&2; exit 2 ;;
esac

RUN_DIR=${RUN_DIR:-.build/deadline-runs/$(date +%Y%m%d-%H%M%S)}
DIAGNOSE_PATTERN=${DIAGNOSE_PATTERN:-xcodebuild|xctest|XCTRunner|xctrunner|testmanagerd|swift-test|swiftpm-testing-helper|swift-build|LayoutDemo}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-3}
KILL_GRACE=${KILL_GRACE:-10}

mkdir -p "$RUN_DIR"
# Absolute, so that a command which changes directory still finds the folder.
RUN_DIR=$(cd "$RUN_DIR" && pwd)
export RUN_DIR

{
  echo "command:  $*"
  echo "deadline: ${deadline}s"
  echo "started:  $(date '+%Y-%m-%d %H:%M:%S')"
} >"$RUN_DIR/command.txt"

# Job control gives the run its own process group, so the whole tree (the build tool, the test
# host, whatever they spawned in the group) can be inspected and stopped together without
# touching this script or the caller's shell.
set -m
(
  set -o pipefail
  "$@" 2>&1 | tee "$RUN_DIR/output.log"
) &
leader=$!
set +m

# A test that has started and neither passed nor failed is where a hang sits. Covers both the
# Swift Testing lines (`◇ Test x started.` / `✔ Test x passed`) and XCTest's
# (`Test Case 'x' started.` / `Test Case 'x' passed`).
unpaired_tests() {
  awk '
    /^◇ Test .* started\./ {
      name = $0; sub(/^◇ Test /, "", name); sub(/ started\..*$/, "", name)
      started[name] = 1; order[++n] = name; next
    }
    /^[✔✘] Test .* (passed|failed) after/ {
      name = $0; sub(/^[✔✘] Test /, "", name); sub(/ (passed|failed) after.*$/, "", name)
      delete started[name]; next
    }
    /^Test Case .* started\./ {
      name = $0; sub(/^Test Case /, "", name); sub(/ started\..*$/, "", name)
      started[name] = 1; order[++n] = name; next
    }
    /^Test Case .* (passed|failed)/ {
      name = $0; sub(/^Test Case /, "", name); sub(/ (passed|failed).*$/, "", name)
      delete started[name]; next
    }
    END { for (i = 1; i <= n; i++) if (order[i] in started) { print order[i]; delete started[order[i]] } }
  ' "$1"
}

collect_diagnostics() {
  local dir=$RUN_DIR/on-deadline
  mkdir -p "$dir"

  {
    echo "# run's process group: $leader (rows marked with *)"
    ps -axo pid,ppid,pgid,stat,etime,time,%cpu,command | awk -v g="$leader" '
      NR == 1 { print "  " $0; next }
      { print ($3 == g ? "* " : "  ") $0 }'
  } >"$dir/processes.txt" 2>&1

  unpaired_tests "$RUN_DIR/output.log" >"$dir/unpaired-tests.txt" 2>&1
  xcrun simctl list devices booted >"$dir/simulators.txt" 2>&1

  # The run's own group plus the processes the pattern names (a test host on a simulator lives
  # outside the group, but it is usually the one that is stuck).
  local pids
  pids=$( {
    pgrep -g "$leader" 2>/dev/null
    pgrep "$DIAGNOSE_PATTERN" 2>/dev/null
  } | sort -un)

  local pid name samplers=""
  for pid in $pids; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)
    [ -n "$name" ] || continue
    # `sample` needs the process to exist and to belong to this user; a failure is recorded in
    # the file rather than hidden, so a missing sample is visible as missing.
    sample "$pid" "$SAMPLE_SECONDS" -file "$dir/sample-$pid-$name.txt" >"$dir/sample-$pid-$name.log" 2>&1 &
    samplers="$samplers $!"
  done
  # Only the samplers: a bare `wait` would also wait for the run itself.
  # shellcheck disable=SC2086
  [ -z "$samplers" ] || wait $samplers
}

elapsed=0
while kill -0 "$leader" 2>/dev/null; do
  if [ "$elapsed" -ge "$deadline" ]; then
    echo "deadline of ${deadline}s reached: collecting diagnostics in $RUN_DIR/on-deadline" >&2
    collect_diagnostics
    kill -TERM -- "-$leader" 2>/dev/null
    grace=0
    while kill -0 "$leader" 2>/dev/null && [ "$grace" -lt "$KILL_GRACE" ]; do
      sleep 1
      grace=$((grace + 1))
    done
    if kill -0 "$leader" 2>/dev/null; then
      kill -KILL -- "-$leader" 2>/dev/null
    fi
    wait "$leader" 2>/dev/null
    echo "deadline ${deadline}" >"$RUN_DIR/exit-status.txt"
    echo "stopped at the deadline; evidence in $RUN_DIR" >&2
    exit 124
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

wait "$leader"
status=$?
echo "finished $status" >"$RUN_DIR/exit-status.txt"
exit "$status"
