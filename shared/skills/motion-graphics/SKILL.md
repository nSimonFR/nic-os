---
name: motion-graphics
description: Router to iart.ai's 56 motion-graphics skills, fetched on demand. Use when asked to make a video or animation (Reels/TikTok, explainer, ad, product demo, chart or map animation, kinetic type, logo reveal, lower thirds, captions, Remotion, Manim) or for web motion beyond basic UI transitions (GSAP/ScrollTrigger, SVG draw-on, Lottie, Three.js, shaders, particles).
---

# Motion graphics (iart.ai packs, loaded on demand)

The 19 [iart-ai](https://github.com/iart-ai/motion-skills) packs are not installed:
their descriptions alone cost ~7.5k tokens per session. Fetch only the pack you need.

1. Pick the skill from the catalog below.
2. Fetch its pack (pulls when already cloned):
   ```sh
   d=~/.cache/motion-skills/<pack>
   if [ -d "$d" ]; then git -C "$d" pull -q --ff-only; else git clone -q --depth 1 https://github.com/iart-ai/<pack> "$d"; fi
   ```
3. Read `$d/skills/<skill>/SKILL.md` and follow it. Its relative paths
   (`references/`, `scripts/`) resolve against `$d/skills/<skill>/`.

Video skills render through Remotion (Node) or Manim (Python), web skills through
standalone HTML; none of those is preinstalled, so use `nix shell` / `npx` for them.

## Catalog — `<pack>`: `<skill>` — use for

**tiktok-video-skills**: `short-form-video` Reels/TikTok/Shorts · `caption-animation` word-by-word / karaoke captions · `countdown-video` · `lower-thirds` name tags
**text-message-video-skills**: `text-message-animation` fake iMessage/chat story video
**youtube-video-skills**: `audiogram` podcast waveform clip · `youtube-intro-outro` channel intro, end screen
**ecommerce-video-skills**: `product-demo-video` app/SaaS demo · `promo-video` sale/discount reveal · `photo-slideshow`
**ad-video-skills**: `ad-creative-video` performance/UGC ad · `launch-video` hype/teaser · `testimonial-video` quote video
**data-animation-skills**: `chart-animation` bar chart race, CSV → video · `animated-infographic` · `presentation-video` deck → video
**explainer-video-skills**: `explainer-video` script + storyboard · `diagram-animation` flowchart/architecture reveal · `isometric-animation` · `whiteboard-animation` · `wrapped-video` year-in-review
**map-animation-skills**: `map-animation` Vox-style zoom, routes, highlighted regions
**web-animation-skills**: `gsap-web` scroll/ScrollTrigger · `svg-animation` draw-on, morph · `lottie-animation` · `micro-interaction` hover, toggle, like button · `page-transition-animation` route transitions · `60fps-animation` jank fixes · `accessible-animation` reduced motion · `glassmorphism` · `ascii-animation` terminal/CLI intro
**motion-design-skills**: `animation-principles` stiff/floaty motion · `remotion-video` React → MP4 · `logo-animation` · `motion-background` mesh/aurora/shader bg · `color-motion` · `shot-composition` · `beat-sync-editing` · `motion-art-direction` · `after-effects` expressions
**kinetic-typography-skills**: `kinetic-typography` split-text reveals, animated headlines
**freelance-motion-skills**: `creative-brief` · `motion-pricing` · `client-revisions` scope creep · `video-delivery-specs` export settings per platform · `brand-motion-guidelines` easing/timing tokens
**webgl-animation-skills**: `threejs-animation` 3D hero, GLTF · `shader-glsl` · `particle-system` confetti, constellations
**manim-skills**: `manim` 3Blue1Brown-style math
**generative-illustration-skills**: `generative-illustration` animated illustration
**javascript-animation-skills**: `javascript-animation` zero-asset canvas film · `soundtrack` music synthesized in code
**lower-thirds-skills**: `lower-thirds` transparent overlays (WebM alpha, ProRes 4444) for OBS/NLEs
**b-roll-skills**: `talking-head-b-roll` b-roll for a talking-head video, timed to the words
**talking-head-skills**: `talking-head` AI presenter from photos + a voice sample
