# Helpers shared by the test scripts (source this file).
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
# retry <seconds> <command...>: run the command until it succeeds or the time is over
retry() {
  local secs=$1; shift
  local end=$((SECONDS + secs))
  until "$@"; do
    [ $SECONDS -lt $end ] || return 1
    sleep 2
  done
}
