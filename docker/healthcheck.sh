#!/usr/bin/env bash
set -eo pipefail
source /opt/ros/humble/setup.bash
source /opt/aruco_ws/install/setup.bash
set -u
nodes="$(ros2 node list --no-daemon --spin-time 5 2>/dev/null)"
grep -F '/camera/camera/v4l2_camera' <<<"$nodes" >/dev/null \
  || grep -F '/camera/camera' <<<"$nodes" >/dev/null
case "${OPERATION_MODE:-practice}" in
  practice|bench)
    grep -F 'aruco_landing_node' <<<"$nodes" >/dev/null
    ;;
  armtest)
    grep -F 'mavros' <<<"$nodes" >/dev/null
    grep -F 'arm_disarm_test' <<<"$nodes" >/dev/null
    ;;
  flight)
    # Before CH7, flight intentionally has no landing node yet.
    grep -F 'mavros' <<<"$nodes" >/dev/null
    ;;
  *) exit 1 ;;
esac
