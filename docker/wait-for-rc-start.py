#!/usr/bin/env python3
import os
import sys
import time

import rclpy
from mavros_msgs.msg import RCIn
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy


class RCStartGate(Node):
    def __init__(self):
        super().__init__("rc_start_gate")
        self.channel = int(os.getenv("RC_START_CHANNEL", "7"))
        self.index = self.channel - 1
        self.low = int(os.getenv("RC_LOW_THRESHOLD", "1200"))
        self.high = int(os.getenv("RC_HIGH_THRESHOLD", "1800"))
        self.hold_seconds = float(os.getenv("RC_HIGH_HOLD_SECONDS", "1.0"))
        self.require_low = os.getenv("REQUIRE_RC_LOW_FIRST", "true").lower() == "true"
        self.low_seen = not self.require_low
        self.high_since = None
        self.accepted = False
        self.last_log = 0.0

        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.create_subscription(RCIn, "/mavros/rc/in", self.on_rc, qos)
        self.get_logger().info(
            f"RC CH{self.channel}を待機: LOW<={self.low}, HIGH>={self.high}, "
            f"hold={self.hold_seconds:.1f}s, low_first={self.require_low}"
        )

    def on_rc(self, msg):
        if self.index < 0 or self.index >= len(msg.channels):
            now = time.monotonic()
            if now - self.last_log >= 5.0:
                self.get_logger().warning(
                    f"RC CH{self.channel}が受信データにありません "
                    f"(channels={len(msg.channels)})"
                )
                self.last_log = now
            return

        value = int(msg.channels[self.index])
        if value <= self.low:
            if not self.low_seen:
                self.get_logger().info(
                    f"RC CH{self.channel} LOWを確認しました。開始スイッチをONにできます。"
                )
            self.low_seen = True
            self.high_since = None
            return

        if not self.low_seen or value < self.high:
            self.high_since = None
            return

        now = time.monotonic()
        if self.high_since is None:
            self.high_since = now
            self.get_logger().info(
                f"RC CH{self.channel} HIGHを検出。保持を確認しています..."
            )
        elif now - self.high_since >= self.hold_seconds:
            self.accepted = True


def main():
    rclpy.init()
    node = RCStartGate()
    try:
        while rclpy.ok() and not node.accepted:
            rclpy.spin_once(node, timeout_sec=0.2)
        if node.accepted:
            node.get_logger().info("RC開始指令を受理しました。")
            return 0
        return 1
    except KeyboardInterrupt:
        return 130
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    sys.exit(main())
