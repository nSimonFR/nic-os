"""Immich CLIP tooling: the sidecar behind the `nic-clip` workflow plugin, plus
the two by-hand tools that feed and calibrate it.

The plugin (hosts/rpi5/immich-clip/plugin.js) cannot do the CLIP part itself —
its only way out is the `httpRequest` host function, which returns
`body: await res.text()`, so no image bytes in and no multipart out. It therefore
asks `clip_filter` for a verdict, and `clip_filter` answers from embeddings
Immich already computed on beast rather than running inference of its own.
"""
