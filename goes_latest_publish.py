"""Publish goes/latest-city-lights.jpg - a stable alias for off-site embeds.

The QRZ bio hotlinks one URL; the mirror's own frames are timestamped and rotate
out after HIST_PUB frames, so a direct link would rot within a day.

Why this runs on hamrig instead of inside home-beast's collector: the alias feeds
a public profile, and HRIT frames are not uniformly usable. Two real failure modes
seen in the wild:
  * a dropped HRIT segment leaves a full-width black stripe across the disk
  * the GeoColor composite occasionally falls back to a single IR channel, giving
    a completely colourless (grey) Earth
A naive "copy the newest frame" would put either straight on the QRZ page. This
picks the newest frame that PASSES both checks, so the profile degrades to a
slightly older good image rather than a broken-looking one.

Reads frames from the local clone (home-beast pushes them there), so it needs no
network beyond git. Writes only goes/latest-city-lights.jpg and never touches the
timestamped history.
"""
import os
import re
import subprocess
import sys

from PIL import Image, ImageStat

REPO = r"C:\w4ewb\W4EWB"
SRC = os.path.join(REPO, "goes", "h", "city-lights")
DST = os.path.join(REPO, "goes", "latest-city-lights.jpg")
CANDIDATES = 8          # how far back to look before giving up
MIN_CHROMA = 3.0        # mean R/G/B spread; below this the frame is greyscale
STAMP = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.jpg$")


def log(msg):
    print(msg, flush=True)


def git(*args, check=True):
    r = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r


def dead_rows(gray, w, h):
    """Rows across the disk interior that are essentially pure black -- the
    signature of a dropped HRIT segment. Genuine night side is dark but never
    uniformly zero all the way across."""
    px = gray.load()
    return sum(1 for y in range(int(h * .05), int(h * .95))
               if max(px[x, y] for x in range(int(w * .3), int(w * .7), 12)) <= 2)


def chroma(rgb):
    means = [ImageStat.Stat(c).mean[0] for c in rgb.split()]
    return max(means) - min(means)


def usable(path):
    with Image.open(path) as im:
        w, h = im.size
        c = chroma(im.convert("RGB"))
        d = dead_rows(im.convert("L"), w, h)
    if d:
        return False, "dropout (%d dead rows)" % d
    if c < MIN_CHROMA:
        return False, "greyscale (chroma %.1f)" % c
    return True, "ok (chroma %.1f)" % c


def main():
    git("pull", "--rebase", "--quiet", check=False)
    if not os.path.isdir(SRC):
        log("no city-lights history yet: %s" % SRC)
        return 0

    frames = sorted((f for f in os.listdir(SRC) if STAMP.match(f)), reverse=True)
    if not frames:
        log("no frames in %s" % SRC)
        return 0

    for name in frames[:CANDIDATES]:
        path = os.path.join(SRC, name)
        try:
            ok, why = usable(path)
        except Exception as e:
            log("skip %s: unreadable (%s)" % (name, e))
            continue
        if not ok:
            log("skip %s: %s" % (name, why))
            continue

        new = open(path, "rb").read()
        if os.path.exists(DST) and open(DST, "rb").read() == new:
            log("alias already current (%s)" % name)
            return 0
        open(DST, "wb").write(new)
        log("alias <- %s (%s)" % (name, why))

        git("add", "goes/latest-city-lights.jpg")
        if not git("diff", "--cached", "--quiet", check=False).returncode:
            log("nothing staged; done")
            return 0
        git("commit", "--quiet", "-m", "Auto GOES alias update %s" % name[:-4])
        for attempt in range(1, 6):          # publishers collide; rebase and retry
            if git("push", "--quiet", check=False).returncode == 0:
                log("pushed")
                return 0
            log("push race, retry %d/5" % attempt)
            git("pull", "--rebase", "--quiet", check=False)
        log("push failed after 5 attempts")
        return 1

    log("no usable frame in the newest %d - alias left unchanged" % CANDIDATES)
    return 0


if __name__ == "__main__":
    sys.exit(main())
