# README images

Run this command from the repository root to regenerate both hero images:

```sh
uv run Scripts/generate-hero.py
```

`wordmark.svg` contains the lettering paths from the original Illustrator export,
with a corrected curve on the P to remove a spur.
The service icons are the same SVG files used in the README table.
The generated images embed these paths and need no fonts or external images.

The icon centers follow a circular arc.
On a circle, arc length equals radius times angle in radians,
so equal angle steps give equal spacing along the curve.
The script calculates each center with `x = width / 2 + radius * sin(angle)`
and `y = arc_top + radius * (1 - cos(angle))`.
The icons stay upright.

The hero icons are ordered by hue, from red through green and blue to purple.
The README table stays in alphabetical order.
To add or reorder icons, edit `SERVICES` in the script.
Each entry contains the asset name and its background color for dark mode.
The light mode color comes from the asset.
Adjust `ICON_SIZE`, `RADIUS`, `ARC_TOP`, and `SWEEP` to change the layout.
If more icons make the arc too crowded, reduce `ICON_SIZE` or increase `SWEEP`.
Regenerate and check both images after changes.

