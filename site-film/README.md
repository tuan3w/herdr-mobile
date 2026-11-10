# site-film

The 24 s film on the landing page (`site/`), written in HTML for
[HyperFrames](https://hyperframes.heygen.com). The phone screens are the app's own renders
(`tool/screenshots/run.sh` raw output, dark theme, resized to 720 px wide), not a phone
recording, and the film says so. Hold ring, "Sent" and touch marks are drawn overlays.

```bash
cd site-film
npx hyperframes@0.9.28 check
npx hyperframes@0.9.28 render -q looks -o renders/herdr-mobile.mp4   # add --docker if Chrome crashes
HERDR_FILM=renders/herdr-mobile.mp4 python3 -I ../tool/build-site.py --assets
```

Why `site-film/` and not `site/`: Pages publishes everything in `site/`, and the project's
renders and `.hyperframes` cache must not ship.
