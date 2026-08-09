FROM ros:humble-ros-base-jammy

ARG DEBIAN_FRONTEND=noninteractive
ARG LIBREALSENSE_VERSION=v2.55.1
ARG REALSENSE_ROS_VERSION=4.55.1
ARG ARUCO_REPOSITORY=https://github.com/Aki0290/aruco_landing_docker.git
ARG ARUCO_REF=main

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ROS_DISTRO=humble \
    ROS_DOMAIN_ID=42 \
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    WS=/opt/aruco_ws

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake curl geographiclib-tools git gpiod \
      libssl-dev libusb-1.0-0-dev \
      pkg-config python3-colcon-common-extensions python3-opencv python3-rosdep \
      ros-humble-cv-bridge ros-humble-image-transport ros-humble-mavros \
      ros-humble-mavros-extras ros-humble-rmw-fastrtps-cpp ros-humble-tf2-ros \
      udev usbutils \
    && geographiclib-get-geoids egm96-5 \
    && rm -rf /var/lib/apt/lists/*

# Raspberry Pi/ARM64ではカーネルパッチ不要のlibuvc（RSUSB）バックエンドを使う。
RUN git clone --depth 1 --branch "${LIBREALSENSE_VERSION}" \
      https://github.com/realsenseai/librealsense.git /tmp/librealsense \
    && cmake -S /tmp/librealsense -B /tmp/librealsense/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DFORCE_RSUSB_BACKEND=ON \
      -DBUILD_EXAMPLES=OFF \
      -DBUILD_GRAPHICAL_EXAMPLES=OFF \
      -DBUILD_PYTHON_BINDINGS=OFF \
      -DBUILD_WITH_CUDA=OFF \
    && cmake --build /tmp/librealsense/build --parallel 2 \
    && cmake --install /tmp/librealsense/build \
    && ldconfig \
    && rm -rf /tmp/librealsense

RUN mkdir -p "${WS}/src" \
    && git clone --depth 1 --branch "${REALSENSE_ROS_VERSION}" \
      https://github.com/realsenseai/realsense-ros.git "${WS}/src/realsense-ros" \
    && git clone --depth 1 --branch "${ARUCO_REF}" \
      "${ARUCO_REPOSITORY}" "${WS}/src/aruco_landing"

COPY docker/patches/operation-modes.patch /tmp/operation-modes.patch
RUN git -C "${WS}/src/aruco_landing" apply /tmp/operation-modes.patch

RUN rosdep update \
    && apt-get update \
    && rosdep install --from-paths "${WS}/src" --ignore-src -r -y \
    && rm -rf /var/lib/apt/lists/* \
    && source /opt/ros/humble/setup.bash \
    && cd "${WS}" \
    && colcon build --merge-install --cmake-args -DCMAKE_BUILD_TYPE=Release \
      --packages-select realsense2_camera_msgs realsense2_description \
        realsense2_camera aruco_landing \
      --parallel-workers 2 \
    && rm -rf "${WS}/build" "${WS}/log"

COPY docker/entrypoint.sh /usr/local/bin/aruco-entrypoint
COPY docker/start-hardware.sh /usr/local/bin/start-hardware
COPY docker/wait-for-rc-start.py /usr/local/bin/wait-for-rc-start
COPY docker/healthcheck.sh /usr/local/bin/aruco-healthcheck
RUN chmod +x /usr/local/bin/aruco-entrypoint /usr/local/bin/start-hardware \
      /usr/local/bin/wait-for-rc-start /usr/local/bin/aruco-healthcheck \
    && mkdir -p /runtime

WORKDIR /runtime
ENTRYPOINT ["/usr/local/bin/aruco-entrypoint"]
CMD ["/usr/local/bin/start-hardware"]
