#!/usr/bin/env python3
"""Set every pixel of the vehicle status LED strip to one colour."""

import argparse
import sys
import time

from rpi_ws281x import Color, PixelStrip, ws


COLOURS = {
    "off": (0, 0, 0),
    "red": (255, 0, 0),
    "green": (0, 255, 0),
    "blue": (0, 0, 255),
    "yellow": (255, 255, 0),
    "purple": (255, 0, 255),
    "cyan": (0, 255, 255),
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("colour", choices=COLOURS)
    parser.add_argument("--gpio", type=int, default=18)
    parser.add_argument("--count", type=int, default=8)
    parser.add_argument("--brightness", type=int, default=64)
    parser.add_argument("--pattern", choices=("solid", "slow", "fast"), default="solid")
    parser.add_argument("--watch", help="continuously read '<colour> <pattern>' from this file")
    args = parser.parse_args()

    if not 1 <= args.count <= 256:
        parser.error("--count must be between 1 and 256")
    if not 0 <= args.brightness <= 255:
        parser.error("--brightness must be between 0 and 255")

    # FuriousFPV FPV-LED1RV2 is an eight-pixel, 5 V, three-wire strip.
    # PWM channel 0 on GPIO18 is used by rpi_ws281x. GRB is the usual order.
    strip = PixelStrip(
        args.count,
        args.gpio,
        800_000,
        10,
        False,
        args.brightness,
        0,
        ws.WS2811_STRIP_GRB,
    )
    def show(colour_name, enabled=True):
        red, green, blue = COLOURS[colour_name] if enabled else COLOURS["off"]
        colour = Color(red, green, blue)
        for pixel in range(strip.numPixels()):
            strip.setPixelColor(pixel, colour)
        strip.show()

    def requested_state():
        if not args.watch:
            return args.colour, args.pattern
        try:
            with open(args.watch, encoding="ascii") as state_file:
                parts = state_file.read().strip().split()
            colour = parts[0] if parts and parts[0] in COLOURS else "red"
            pattern = parts[1] if len(parts) > 1 and parts[1] in ("solid", "slow", "fast") else "solid"
            return colour, pattern
        except OSError:
            return "red", "fast"

    try:
        strip.begin()
        if not args.watch and args.pattern == "solid":
            show(args.colour)
            return 0
        phase_on = True
        previous = None
        while True:
            colour, pattern = requested_state()
            current = (colour, pattern)
            if current != previous:
                phase_on = True
                previous = current
            show(colour, pattern == "solid" or phase_on)
            if pattern == "solid":
                time.sleep(0.1)
            else:
                time.sleep(0.25 if pattern == "fast" else 0.75)
                phase_on = not phase_on
    except Exception as exc:  # hardware errors must be visible in the LED log
        print(f"status LED error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
