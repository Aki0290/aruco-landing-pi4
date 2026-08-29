#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="${ARUCO_NATIVE_WS:-$HOME/aruco_ws}"
librealsense_version="${LIBREALSENSE_VERSION:-v2.58.3}"
realsense_ros_version="${REALSENSE_ROS_VERSION:-4.55.1}"
aruco_repository="${ARUCO_REPOSITORY:-https://github.com/Aki0290/aruco_landing_docker.git}"
aruco_ref="${ARUCO_REF:-main}"

log() { printf '\n==> %s\n' "$*"; }
[[ "$(uname -m)" == aarch64 ]] || log "注意: この手順はPi 4 ARM64向けです（現在: $(uname -m)）。"

log "ROS 2 HumbleのAPTリポジトリを設定します"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common
sudo add-apt-repository -y universe
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/ros-archive-keyring.gpg
arch="$(dpkg --print-architecture)"
codename="$(. /etc/os-release && printf '%s' "$UBUNTU_CODENAME")"
echo "deb [arch=${arch} signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu ${codename} main" \
  | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null

log "ROS 2とビルド依存をインストールします"
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake git libssl-dev libusb-1.0-0-dev pkg-config udev usbutils \
  python3-colcon-common-extensions python3-opencv python3-rosdep \
  ros-humble-ros-base ros-humble-cv-bridge ros-humble-image-transport \
  ros-humble-rmw-fastrtps-cpp ros-humble-tf2-ros

log "librealsense ${librealsense_version}をRSUSBバックエンドで構築します"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
git clone --depth 1 --branch "$librealsense_version" \
  https://github.com/realsenseai/librealsense.git "$build_dir/librealsense"
cmake -S "$build_dir/librealsense" -B "$build_dir/librealsense/build" \
  -DCMAKE_BUILD_TYPE=Release -DFORCE_RSUSB_BACKEND=ON \
  -DBUILD_EXAMPLES=OFF -DBUILD_GRAPHICAL_EXAMPLES=OFF \
  -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_WITH_CUDA=OFF
cmake --build "$build_dir/librealsense/build" --parallel 2
sudo cmake --install "$build_dir/librealsense/build"
sudo ldconfig
sudo "$build_dir/librealsense/scripts/setup_udev_rules.sh"

log "ROSワークスペースを準備します: ${workspace}"
mkdir -p "$workspace/src"
if [[ ! -d "$workspace/src/realsense-ros/.git" ]]; then
  git clone --depth 1 --branch "$realsense_ros_version" \
    https://github.com/realsenseai/realsense-ros.git "$workspace/src/realsense-ros"
fi
if [[ ! -d "$workspace/src/aruco_landing/.git" ]]; then
  git clone --depth 1 --branch "$aruco_ref" "$aruco_repository" "$workspace/src/aruco_landing"
fi

patch_file="$root/docker/patches/operation-modes.patch"
if git -C "$workspace/src/aruco_landing" apply --check "$patch_file" 2>/dev/null; then
  git -C "$workspace/src/aruco_landing" apply "$patch_file"
elif git -C "$workspace/src/aruco_landing" apply --reverse --check "$patch_file" 2>/dev/null; then
  log "practice安全パッチは適用済みです"
else
  echo "ERROR: practice安全パッチを適用できません。上流コードの版を確認してください。" >&2
  exit 1
fi

if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  sudo rosdep init
fi
rosdep update
sudo apt-get update
rosdep install --from-paths "$workspace/src" --ignore-src -r -y

log "RealSense ROSとArUcoノードをビルドします"
source /opt/ros/humble/setup.bash
cd "$workspace"
colcon build --merge-install --cmake-args \
  -DCMAKE_BUILD_TYPE=Release -Drealsense2_DIR=/usr/local/lib/cmake/realsense2 \
  --packages-select realsense2_camera_msgs realsense2_description \
    realsense2_camera aruco_landing --parallel-workers 2

log "完了しました。D455を一度抜き差しして、次を実行してください:"
printf '  cd %q\n  ./diagnose-native-practice.sh\n  ./run-native-practice.sh\n' "$root"
