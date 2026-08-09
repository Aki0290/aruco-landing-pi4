#!/usr/bin/env bash
set -e

source /opt/ros/humble/setup.bash
source /opt/aruco_ws/install/setup.bash

export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"

mkdir -p /runtime/logs
exec "$@"
