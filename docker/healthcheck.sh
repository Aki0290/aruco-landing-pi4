#!/usr/bin/env bash
set -euo pipefail
source /opt/ros/humble/setup.bash
source /opt/aruco_ws/install/setup.bash
ros2 topic list 2>/dev/null | grep -q '^/camera/camera/color/image_raw$'
ros2 node list 2>/dev/null | grep -q 'aruco_landing_node'
if [[ "${OPERATION_MODE:-practice}" != "practice" ]]; then
  ros2 node list 2>/dev/null | grep -q 'mavros'
fi
