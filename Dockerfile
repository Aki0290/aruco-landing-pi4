FROM ros:humble-ros-base-jammy

ARG DEBIAN_FRONTEND=noninteractive
ARG LIBREALSENSE_VERSION=v2.58.3
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
    && colcon build --merge-install --cmake-args \
      -DCMAKE_BUILD_TYPE=Release \
      -Drealsense2_DIR=/usr/local/lib/cmake/realsense2 \
      --packages-select realsense2_camera_msgs realsense2_description \
        realsense2_camera aruco_landing \
      --parallel-workers 2 \
    && rm -rf "${WS}/build" "${WS}/log"

# Pythonのみの検出モードはビルド後に適用し、重いROS再ビルドを避ける。
COPY docker/patches/detection-only.patch /tmp/detection-only.patch
RUN git -C "${WS}/src/aruco_landing" apply /tmp/detection-only.patch \
    && patch -p1 -d "${WS}/install/lib/python3.10/site-packages" \
      < /tmp/detection-only.patch

# 後段に置き、USBカメラ機能の変更で重いlibrealsenseビルドを無効化しない。
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-rpi-ws281x ros-humble-v4l2-camera ros-humble-camera-calibration \
    && rm -rf /var/lib/apt/lists/*

COPY docker/overlays/landing_node.py \
  ${WS}/src/aruco_landing/aruco_landing/landing_node.py
COPY docker/overlays/landing_node.py \
  ${WS}/install/lib/python3.10/site-packages/aruco_landing/landing_node.py

COPY docker/entrypoint.sh /usr/local/bin/aruco-entrypoint
COPY docker/start-hardware.sh /usr/local/bin/start-hardware
COPY docker/wait-for-rc-start.py /usr/local/bin/wait-for-rc-start
COPY docker/arm-disarm-test.py /usr/local/bin/arm-disarm-test
COPY docker/status-led-ws281x.py /usr/local/bin/status-led-ws281x
COPY docker/healthcheck.sh /usr/local/bin/aruco-healthcheck
RUN chmod +x /usr/local/bin/aruco-entrypoint /usr/local/bin/start-hardware \
      /usr/local/bin/wait-for-rc-start /usr/local/bin/arm-disarm-test \
      /usr/local/bin/status-led-ws281x \
      /usr/local/bin/aruco-healthcheck \
    && mkdir -p /runtime

WORKDIR /runtime
ENTRYPOINT ["/usr/local/bin/aruco-entrypoint"]
CMD ["/usr/local/bin/start-hardware"]
