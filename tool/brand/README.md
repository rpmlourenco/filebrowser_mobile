The launcher and splash use the official FileBrowser Quantum icon from
https://github.com/gtsteffaniak/filebrowser/blob/main/frontend/public/img/icons/favicon.svg
(upstream blob 57f5951f378c1f48826cd09b02977cc7976eaa5d).
The original SVG is preserved in quantum-official.svg. Adaptive layers only
adjust its placement to fit Android's safe area; the monochrome layer uses
the same folder silhouettes.

Regenerate all Android densities and previews with:

    python -m pip install resvg-py==0.5.0 Pillow
    python tool/brand/render.py

This is an unofficial Android client fork, not an official Quantum app.
