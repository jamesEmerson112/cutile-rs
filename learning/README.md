# learning/

Fork-only study material for understanding cuTile Rust. Like `pod/`, this folder exists only on the fork's `main` and should never be part of an upstream PR.

## threads-vs-tiles/

An interactive, step-through animation that explains how cuTile's tile programming differs from CUDA's thread programming. It uses one practical case throughout: brightening a 16 x 16 photo by multiplying every pixel by 1.5. The seven scenes cover the CUDA thread-per-pixel approach, cuTile partitioning, one tile program's load, compute, and store, edge tiles, what CUDA runs underneath, and a small playground.

Open it in a browser:

```bash
open learning/threads-vs-tiles/index.html
```

The page is a single self-contained HTML file with no build step. Every claim follows the cuTile book in `cutile-book/`, mainly `guide/useful-mental-models.md`, `guide/tensors-and-tiles.md`, and tutorials 02 and 03.
