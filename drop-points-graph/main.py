"""
Gulp fight drop-target positions visualiser.
26 entries from GulpDropTargetTable at 0x80120c98 (SCUS_944.25).
Entry 0 = center of the arena (reference/home), entries 1-25 = selectable drop targets.
Coordinates are signed 32-bit integers in Insomniac's PS1 world-unit system.

Usage:
    uv run main.py --delaunay
    uv run main.py --threshold 5000
    uv run main.py --threshold-pair 25 10
    uv run main.py --delaunay --threshold-pair 14 12
    uv run main.py --delaunay --exclude-edge 24 19
"""

import argparse
import math
import matplotlib.pyplot as plt
from scipy.spatial import Delaunay
import numpy as np

# fmt: off
# Each tuple is (index, x, y) — z is identical for all (18944 = 0x4A00) so ignored.
# Parsed from raw memory at 0x80120c98; entries begin after a 12-byte table header.
DROP_TARGETS = [
    # index  x       y
    (  0, 36864,  40960),  # arena center (reference point)
    (  1, 40960,  36864),
    (  2, 41574,  42189),
    (  3, 39844,  45394),
    (  4, 32768,  43008),
    (  5, 34816,  36864),
    (  6, 36741,  34621),
    (  7, 32061,  39567),
    (  8, 34029,  47104),
    (  9, 37274,  50022),
    ( 10, 44298,  45517),
    ( 11, 45414,  42506),
    ( 12, 43868,  37540),
    ( 13, 42660,  33536),
    ( 14, 39055,  31805),
    ( 15, 31805,  34826),
    ( 16, 28928,  38574),
    ( 17, 29327,  42516),
    ( 18, 30536,  46930),
    ( 19, 33628,  49060),
    ( 20, 34673,  32317),
    ( 21, 36864,  44237),
    ( 22, 38502,  38912),
    ( 23, 46080,  39629),
    ( 24, 27935,  45394),
    ( 25, 41288,  49551),
]
# fmt: on

# Manually excluded edges (stored as local indices = table index - 1).
# table 24↔19 (local 23↔18): skips over 18 which sits between them.
# Distances: 24-19=6771, 24-18=3021, 18-19=3755.
EXCLUDED_EDGES: set[frozenset] = {
    frozenset((23, 18)),
}

# Manually forced edges that triangulation misses (stored as local indices = table index - 1).
# table 15↔6 (local 14↔5): nearly horizontal neighbours, distance 4940, Delaunay skips them.
FORCED_EDGES: set[frozenset] = {
    frozenset((14, 5)),
}


def target_xy(table_index):
    _, x, y = DROP_TARGETS[table_index]
    return (x, y)


def build_delaunay_edges(points):
    tri = Delaunay(points)
    edges = set()
    for a, b, c in tri.simplices:
        edges.add(frozenset((a, b)))
        edges.add(frozenset((b, c)))
        edges.add(frozenset((a, c)))
    return edges


def build_threshold_edges(points, threshold):
    n = len(points)
    edges = set()
    for i in range(n):
        for j in range(i + 1, n):
            if math.dist(points[i], points[j]) <= threshold:
                edges.add(frozenset((i, j)))
    return edges


def main():
    parser = argparse.ArgumentParser(description="Gulp drop-target graph visualiser")
    parser.add_argument("--delaunay", action="store_true", help="Add Delaunay triangulation edges")

    thresh_group = parser.add_mutually_exclusive_group()
    thresh_group.add_argument(
        "--threshold",
        type=float,
        default=None,
        metavar="DISTANCE",
        help="Add edges within this absolute distance",
    )
    thresh_group.add_argument(
        "--threshold-pair",
        type=int,
        nargs=2,
        metavar=("A", "B"),
        help="Add edges within the distance between two table positions (0-25)",
    )
    parser.add_argument(
        "--exclude-edge",
        type=int,
        nargs=2,
        metavar=("A", "B"),
        action="append",
        dest="exclude_edges",
        default=[],
        help="Manually exclude an edge by table index pair (repeatable)",
    )
    parser.add_argument(
        "--include-edge",
        type=int,
        nargs=2,
        metavar=("A", "B"),
        action="append",
        dest="include_edges",
        default=[],
        help="Manually force an edge by table index pair (repeatable)",
    )
    args = parser.parse_args()

    # Default to delaunay if nothing specified
    if not args.delaunay and args.threshold is None and args.threshold_pair is None:
        args.delaunay = True

    # Resolve threshold
    threshold = None
    thresh_label = None
    if args.threshold_pair is not None:
        a, b = args.threshold_pair
        threshold = math.dist(target_xy(a), target_xy(b))
        thresh_label = f"dist({a}↔{b})={threshold:.0f}"
        print(f"  threshold: distance between positions {a} and {b} = {threshold:.2f}")
    elif args.threshold is not None:
        threshold = args.threshold
        thresh_label = f"{threshold:.0f}"
        print(f"  threshold: {threshold:.2f}")

    # Build excluded/forced edge sets: hardcoded + any passed via CLI
    excluded = set(EXCLUDED_EDGES)
    for a, b in args.exclude_edges:
        excluded.add(frozenset((a - 1, b - 1)))

    forced = set(FORCED_EDGES)
    for a, b in args.include_edges:
        forced.add(frozenset((a - 1, b - 1)))

    pts = np.array([(x, y) for _, x, y in DROP_TARGETS[1:]])
    pts_list = pts.tolist()

    # Accumulate edges
    edges: set = set()
    active_methods = []

    if args.delaunay:
        new_edges = build_delaunay_edges(pts_list)
        overlap = len(new_edges & edges)
        edges |= new_edges
        active_methods.append("delaunay")
        print(f"  delaunay: {len(new_edges)} edges ({overlap} already present, {len(new_edges) - overlap} new)")

    if threshold is not None:
        new_edges = build_threshold_edges(pts_list, threshold)
        overlap = len(new_edges & edges)
        edges |= new_edges
        active_methods.append(f"threshold({thresh_label})")
        print(f"  threshold: {len(new_edges)} edges ({overlap} already present, {len(new_edges) - overlap} new)")

    before = len(edges)
    edges -= excluded
    if excluded:
        print(f"  excluded: removed {before - len(edges)} edge(s)")

    added = forced - edges
    edges |= forced
    if forced:
        print(f"  forced: added {len(added)} edge(s)")

    print(f"  total unique edges: {len(edges)}")

    # Plot
    fig, ax = plt.subplots(figsize=(8, 8), facecolor="#1a1a2e")
    ax.set_facecolor("#16213e")

    center = DROP_TARGETS[0]
    targets = DROP_TARGETS[1:]

    for edge in edges:
        i, j = tuple(edge)
        x0, y0 = pts[i]
        x1, y1 = pts[j]
        ax.plot([x0, x1], [y0, y1], color="#2a4a6a", linewidth=1.0, zorder=1)

    ax.scatter(pts[:, 0], pts[:, 1], color="#00d4ff", s=120, zorder=3, label="Drop targets (1–25)")
    for idx, x, y in targets:
        ax.annotate(str(idx), (x, y), textcoords="offset points", xytext=(6, 4),
                    fontsize=7, color="#00d4ff", fontweight="bold")

    ax.scatter([center[1]], [center[2]], color="#ff6b35", s=200, marker="*",
               zorder=4, label="Arena center (0)")
    ax.annotate("0 (center)", (center[1], center[2]), textcoords="offset points",
                xytext=(8, 4), fontsize=7, color="#ff6b35", fontweight="bold")

    ax.set_title(f"Gulp Fight — Drop Target Graph ({' + '.join(active_methods)})",
                 color="white", fontsize=12, pad=12)
    ax.set_xlabel("World X", color="#888888")
    ax.set_ylabel("World Y", color="#888888")
    ax.tick_params(colors="#888888")
    for spine in ax.spines.values():
        spine.set_edgecolor("#333366")
    ax.grid(True, color="#222244", linewidth=0.5, linestyle="--")
    ax.legend(facecolor="#1a1a2e", edgecolor="#333366", labelcolor="white", fontsize=9)
    ax.set_aspect("equal")

    out = "drop_targets.png"
    plt.tight_layout()
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Saved → {out}  (edges={len(edges)})")


if __name__ == "__main__":
    main()
