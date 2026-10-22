#!/usr/bin/env bash
set -euo pipefail
TO="${VOILA_TEST_TIMEOUT:-90}"
for m in /tmp/zig-fuse-run-mnt-*; do
  [ -d "$m" ] || continue
  timeout 2 fusermount3 -u "$m" 2>/dev/null || timeout 2 umount "$m" 2>/dev/null || true
  rmdir "$m" 2>/dev/null || true
done
run() {
  local name="$1"
  shift
  echo "==> $name"
  if timeout "$TO" "$@" ; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (exit $?)"
    return 1
  fi
}
failures=0
run "userns-probe" voila userns-probe || failures=$((failures+1))
run "echo" voila run --rm alpine /bin/echo hi || failures=$((failures+1))
run "exit-code" sh -c 'voila run --rm alpine /bin/sh -c "exit 42"; test $? = 42' || failures=$((failures+1))
run "env-e" voila run --rm -e FOO=bar alpine /bin/sh -c 'test "$FOO" = bar' || failures=$((failures+1))
run "workdir-w" sh -c 'out=$(voila run --rm -w /tmp alpine /bin/pwd); test "$out" = /tmp' || failures=$((failures+1))
tmpdir=$(mktemp -d)
echo bindme > "$tmpdir/file"
run "volume-v" sh -c "voila run --rm -v $tmpdir:/mnt:ro alpine /bin/cat /mnt/file | grep -q bindme" || failures=$((failures+1))
run "port-p" sh -c 'voila run -d --rm -p 18080:80 nginx; sleep 3; curl -fsS -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/ | grep -qE "200|301|302"' || failures=$((failures+1))
run "interactive-it" sh -c 'script -q -c "voila run --rm -it alpine /bin/sh -c \"echo tty-ok\"" /dev/null | grep -q tty-ok' || failures=$((failures+1))
exit "$failures"
