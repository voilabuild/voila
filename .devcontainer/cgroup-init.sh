#!/bin/bash
# cgroup v2 nesting fix for running runc inside a privileged container.
#
# The container's root cgroup has processes in it, and cgroup v2's
# "no internal processes" rule forbids enabling controllers for child
# cgroups while the parent has member processes. Same approach as the
# official docker:dind image: move every process into an /init leaf,
# then delegate controllers to the subtree so nested runc can create
# its own cgroups.
#
# The move+enable is retried: a process that forks between reading
# cgroup.procs and the subtree_control write lands back in the root
# cgroup and makes the write fail with EBUSY.
set -u

CG=/sys/fs/cgroup
[ -f "$CG/cgroup.controllers" ] || { echo "cgroup v2 not mounted; skipping"; exit 0; }

mkdir -p "$CG/init"
controllers="$(cat "$CG/cgroup.controllers")"

for attempt in 1 2 3 4 5; do
    # Move all current root-cgroup processes into the init leaf
    # (kernel threads may refuse; that's fine).
    while read -r pid; do
        echo "$pid" > "$CG/init/cgroup.procs" 2>/dev/null || true
    done < "$CG/cgroup.procs"

    # shellcheck disable=SC2086
    if [ -z "$controllers" ] || printf '+%s ' $controllers > "$CG/cgroup.subtree_control" 2>/dev/null; then
        echo "cgroup-init done (attempt $attempt): subtree_control = $(cat "$CG/cgroup.subtree_control")"
        exit 0
    fi
    sleep 0.2
done

echo "cgroup-init WARNING: could not enable subtree controllers after 5 attempts;" \
     "nested runc may fail to apply resource limits" >&2
exit 0
