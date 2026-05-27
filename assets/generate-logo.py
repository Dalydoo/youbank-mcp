"""
Generates the 400x400 youbank-mcp logo PNG from scratch.

Pure Pillow — no external assets. Produces a square with rounded corners,
near-black background (#0A0A0A), and a centred gold (#FFC107) bold "Y"
glyph drawn from straight strokes (clean geometric look matching the
YouBank brand).

Run:
    python assets/generate-logo.py
Outputs:
    assets/logo-400.png
"""

from PIL import Image, ImageDraw

SIZE = 400
CORNER_RADIUS = 72            # ~18% radius — modern app-icon look
BG = (10, 10, 10, 255)        # #0A0A0A
GOLD = (255, 193, 7, 255)     # #FFC107

OUT = "assets/logo-400.png"


def main() -> None:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded-square background.
    draw.rounded_rectangle(
        (0, 0, SIZE - 1, SIZE - 1),
        radius=CORNER_RADIUS,
        fill=BG,
    )

    # Clean geometric Y via two diagonal strokes + one vertical stem.
    # Stroke width is constant; the diagonals fade into the vertical at the fork.
    stroke = 56            # stroke thickness in px
    y_top = 100            # top of the Y arms
    y_bottom = SIZE - 80   # bottom of the stem
    fork_y = int(SIZE * 0.55)  # where the two arms meet the stem
    cx = SIZE // 2
    arm_outer_x_left = 100
    arm_outer_x_right = SIZE - 100

    # Use draw.line with rounded caps via a separate composite step:
    # Pillow's draw.line supports `width` but no cap style. We'll layer
    # circles at each endpoint for clean rounded caps.

    def stroke_segment(p1: tuple[int, int], p2: tuple[int, int]) -> None:
        draw.line([p1, p2], fill=GOLD, width=stroke)
        # Rounded caps at both endpoints.
        r = stroke // 2
        draw.ellipse((p1[0] - r, p1[1] - r, p1[0] + r, p1[1] + r), fill=GOLD)
        draw.ellipse((p2[0] - r, p2[1] - r, p2[0] + r, p2[1] + r), fill=GOLD)

    # Left arm — diagonal from top-left down to the fork.
    stroke_segment((arm_outer_x_left, y_top), (cx, fork_y))
    # Right arm — diagonal from top-right down to the fork.
    stroke_segment((arm_outer_x_right, y_top), (cx, fork_y))
    # Vertical stem.
    stroke_segment((cx, fork_y), (cx, y_bottom))

    img.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
