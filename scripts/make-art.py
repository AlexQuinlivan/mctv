#!/usr/bin/env python3
"""Build the tvOS app icon and Top Shelf images from Minecraft's own artwork,
in the style of the old Minecraft: Apple TV Edition.

    build/art-venv/bin/python scripts/make-art.py [minecraft version] [--key-art]

--key-art uses Mojang's key art for the Top Shelf instead. Save it from
KEY_ART_PAGE as build/art-src/MC_key_art.png in a browser, since the wiki
turns scripts away.
"""
import hashlib
import json
import math
import os
import shutil
import sys
import urllib.request
import zipfile

from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "build", "art-src")
XCASSETS = os.path.join(ROOT, "mctv", "Resources", "Assets.xcassets")
BRAND = os.path.join(XCASSETS, "App Icon & Top Shelf Image.brandassets")
HERO = os.path.join(ROOT, "mctv", "TopShelf", "Resources")  # the Top Shelf extension's full-screen art
INFO = {"author": "xcode", "version": 1}

KEY_ART_PAGE = "https://minecraft.wiki/w/File:MC_key_art.png"
KEY_ART_SHA256 = "79872fa40dac1ef3f5a20963ae36a56a9791c89b80adbe24fb0c794c792926b3"
PANORAMA = "minecraft/textures/gui/title/background/panorama_%d.png"
# The title screen camera, from CubeMap and GuiRenderer (the same in 1.21.11
# and 26.3). It faces panorama face 0 because the spin starts at 0.
TITLE_VFOV = 85.0
TITLE_PITCH = 10.0
# Panorama faces as (normal, right, down). Face 0 is ahead (+z), faces 1 to 3
# go round to the right, and +y is up. Faces 4 and 5 (sky and ground) are
# oriented so their edges meet the sides.
FACES = [((0, 0, 1), (1, 0, 0), (0, -1, 0)), ((1, 0, 0), (0, 0, -1), (0, -1, 0)),
         ((0, 0, -1), (-1, 0, 0), (0, -1, 0)), ((-1, 0, 0), (0, 0, 1), (0, -1, 0)),
         ((0, 1, 0), (1, 0, 0), (0, 0, 1)), ((0, -1, 0), (1, 0, 0), (0, 0, -1))]
MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
ASSETS = "https://resources.download.minecraft.net/%s/%s"
USE_KEY_ART = "--key-art" in sys.argv
JAR_FILES = {
    "minecraft.png": "assets/minecraft/textures/gui/title/minecraft.png",
    "edition.png": "assets/minecraft/textures/gui/title/edition.png",
    "grass_block_side.png": "assets/minecraft/textures/block/grass_block_side.png",
}


def game_dir(version):
    """The version's game folder, as mc_track in scripts/lib.sh has it."""
    return os.path.join(ROOT, "build", "mcgame" if version.startswith("1.") else "mc26")


def sources(version):
    os.makedirs(SRC, exist_ok=True)
    jar = os.path.join(game_dir(version), "versions", version, version + ".jar")
    if not os.path.exists(jar):
        sys.exit("no %s: run scripts/fetch-minecraft.py first" % jar)
    with zipfile.ZipFile(jar) as z:
        for name, member in JAR_FILES.items():
            with open(os.path.join(SRC, name), "wb") as f:
                f.write(z.read(member))
    panorama(version)
    if USE_KEY_ART:
        art = os.path.relpath(os.path.join(SRC, "MC_key_art.png"), ROOT)
        if not os.path.exists(os.path.join(ROOT, art)):
            sys.exit("--key-art: save the image on %s as %s first" % (KEY_ART_PAGE, art))
        if sha256(os.path.join(ROOT, art)) != KEY_ART_SHA256:
            sys.exit("%s isn't the key art this was made for (SHA-256 mismatch). Check it and update KEY_ART_SHA256" % art)


def panorama(version):
    """Copy the version's six title panorama faces into SRC, from the game
    folder if it has them, else from Mojang's asset servers."""
    out = [os.path.join(SRC, "panorama_%d.png" % i) for i in range(6)]
    game = game_dir(version)
    meta = os.path.join(game, "versions", version, version + ".json")
    if os.path.exists(meta):
        with open(meta) as f:
            index = json.load(f)["assetIndex"]["id"]
        path = os.path.join(game, "assets", "indexes", index + ".json")
        if os.path.exists(path):
            with open(path) as f:
                objects = json.load(f)["objects"]
            local = [os.path.join(game, "assets", "objects", objects[PANORAMA % i]["hash"][:2], objects[PANORAMA % i]["hash"])
                     for i in range(6)]
            if all(os.path.exists(p) for p in local):
                for src, dst in zip(local, out):
                    shutil.copyfile(src, dst)
                return
    have = [p for p in out if os.path.exists(p)]
    listing = next(v for v in get_json(MANIFEST)["versions"] if v["id"] == version)
    objects = get_json(get_json(listing["url"])["assetIndex"]["url"])["objects"]
    for i, dst in enumerate(out):
        h = objects[PANORAMA % i]["hash"]
        if dst in have and hashlib.sha1(open(dst, "rb").read()).hexdigest() == h:
            continue
        with urllib.request.urlopen(ASSETS % (h[:2], h), timeout=60) as r:
            data = r.read()
        if hashlib.sha1(data).hexdigest() != h:
            sys.exit("panorama_%d from Mojang didn't match its SHA-1" % i)
        with open(dst, "wb") as f:
            f.write(data)
    print("[art] fetched %s's title panorama from Mojang" % version)


def get_json(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def img(name):
    return Image.open(os.path.join(SRC, name)).convert("RGBA")


def logo():
    """The wordmark with the edition tag under it, as on the title screen. In
    GUI units the wordmark is 256x44 and the tag overlaps its bottom by 7.
    Both textures are 4 pixels per unit."""
    mark, tag = img("minecraft.png"), img("edition.png")
    mark = mark.crop(mark.getbbox())
    tag = tag.crop(tag.getbbox())
    out = Image.new("RGBA", (mark.width, (44 - 7) * 4 + tag.height), (0, 0, 0, 0))
    out.alpha_composite(mark, (0, 0))
    out.alpha_composite(tag, ((mark.width - tag.width) // 2, (44 - 7) * 4))
    return out


def scaled(im, width):
    return im.resize((round(width), round(im.height * width / im.width)), Image.LANCZOS)


def shadow(im, blur, alpha):
    a = im.getchannel("A").point(lambda v: v * alpha // 255)
    s = Image.new("RGBA", im.size, (0, 0, 0, 0))
    s.putalpha(a)
    pad = int(blur * 3)
    big = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    big.alpha_composite(s, (pad, pad))
    return big.filter(ImageFilter.GaussianBlur(blur)), pad


# -- icon ------------------------------------------------------------------------

def icon_layers(w, h):
    texel = w // 16  # 16 texels across, as on the Apple TV Edition icon
    grass = img("grass_block_side.png").resize((16 * texel, 16 * texel), Image.NEAREST)
    back = grass.crop((0, 0, w, h)).convert("RGB")

    mark = scaled(logo(), w * 0.80)
    x, y = (w - mark.width) // 2, int(h * 0.56 - mark.height / 2)
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    front.alpha_composite(mark, (x, y))

    sh, pad = shadow(mark, blur=w / 90, alpha=150)
    middle = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    middle.alpha_composite(sh, (x - pad, y - pad + int(h * 0.02)))
    return {"Back": back, "Middle": middle, "Front": front}


def write_imagestack(name, sizes):
    stack = os.path.join(BRAND, name + ".imagestack")
    layers = [{"filename": n + ".imagestacklayer"} for n in ("Front", "Middle", "Back")]
    write_json(os.path.join(stack, "Contents.json"), {"info": INFO, "layers": layers})
    images = {n: [] for n in ("Front", "Middle", "Back")}
    for (w, h), suffix, tag in sizes:
        for n, im in icon_layers(w, h).items():
            fname = "%s%s.png" % (n.lower(), suffix)
            d = os.path.join(stack, n + ".imagestacklayer", "Content.imageset")
            os.makedirs(d, exist_ok=True)
            im.save(os.path.join(d, fname))
            images[n].append({"filename": fname, "idiom": "tv", "scale": tag})
    for n in images:
        write_json(os.path.join(stack, n + ".imagestacklayer", "Contents.json"), {"info": INFO})
        write_json(os.path.join(stack, n + ".imagestacklayer", "Content.imageset", "Contents.json"),
                   {"images": images[n], "info": INFO})


# -- Top Shelf -----------------------------------------------------------------

def with_logo(canvas, width, top):
    """Draw the title logo `width` wide and centred, with its top at `top` and a soft shadow."""
    mark = scaled(logo(), width)
    x = (canvas.width - mark.width) // 2
    sh, pad = shadow(mark, blur=max(2, mark.height / 14), alpha=140)
    canvas.alpha_composite(sh, (x - pad, top - pad + max(1, round(mark.height * 0.06))))
    canvas.alpha_composite(mark, (x, top))
    return canvas


def has_key_art():
    return USE_KEY_ART


def panorama_view(w, h, vfov=TITLE_VFOV, pitch=TITLE_PITCH, yaw=0.0):
    """Render what the title screen camera sees of the panorama at w x h,
    turned `yaw` degrees right and tilted `pitch` degrees down. Bilinear, like
    the game's sampling."""
    import numpy as np
    faces = [np.asarray(img("panorama_%d.png" % i).convert("RGB"), dtype=np.float32) for i in range(6)]
    n = faces[0].shape[0]
    f = (h / 2) / math.tan(math.radians(vfov) / 2)
    x, y = np.meshgrid(np.arange(w, dtype=np.float32) + 0.5 - w / 2,
                       h / 2 - (np.arange(h, dtype=np.float32) + 0.5))
    z = np.full_like(x, f)
    p, q = math.radians(pitch), math.radians(yaw)
    y, z = y * math.cos(p) - z * math.sin(p), y * math.sin(p) + z * math.cos(p)
    x, z = x * math.cos(q) + z * math.sin(q), z * math.cos(q) - x * math.sin(q)
    d = np.stack([x, y, z], axis=-1)
    normals = np.array([fc[0] for fc in FACES], dtype=np.float32)
    dots = d @ normals.T
    which = dots.argmax(axis=-1)
    out = np.zeros((h, w, 3), dtype=np.float32)
    for k, (normal, right, down) in enumerate(FACES):
        m = which == k
        if not m.any():
            continue
        dk, dn = d[m], dots[m, k]
        u = (dk @ np.array(right, dtype=np.float32)) / dn
        v = (dk @ np.array(down, dtype=np.float32)) / dn
        px = np.clip((u + 1) / 2 * n - 0.5, 0, n - 1)
        py = np.clip((v + 1) / 2 * n - 0.5, 0, n - 1)
        x0, y0 = np.floor(px).astype(int), np.floor(py).astype(int)
        x1, y1 = np.minimum(x0 + 1, n - 1), np.minimum(y0 + 1, n - 1)
        fx, fy = (px - x0)[:, None], (py - y0)[:, None]
        t = faces[k]
        out[m] = (t[y0, x0] * (1 - fx) * (1 - fy) + t[y0, x1] * fx * (1 - fy)
                  + t[y1, x0] * (1 - fx) * fy + t[y1, x1] * fx * fy)
    return Image.fromarray(out.round().astype(np.uint8), "RGB").convert("RGBA")


def title_screen(w, h):
    """The title screen without its buttons, w x h at 16:9. The logo sits 30
    GUI units from the top, with 480 units across at 1080p (GUI scale 4). The
    panorama renders at most 2560 wide, already finer than its 1024 pixel
    faces, and is scaled up from there."""
    rw = min(w, 2560)
    canvas = panorama_view(rw, round(h * rw / w))
    if rw != w:
        canvas = canvas.resize((w, h), Image.LANCZOS)
    unit = w / 480
    mark = logo()  # 4 texture pixels per GUI unit
    mark = mark.resize((round(mark.width * unit / 4), round(mark.height * unit / 4)), Image.LANCZOS)
    canvas.alpha_composite(mark, ((w - mark.width) // 2, round(30 * unit)))
    return canvas


def hero(w, h):
    """Full-screen 16:9 art for the Top Shelf extension. With --key-art it's
    the key art with the logo in the sky, as the Apple TV Edition had it."""
    if has_key_art():
        art = img("MC_key_art.png").resize((w, h), Image.LANCZOS)
        return with_logo(art, w * 0.36, round(h * 0.045)).convert("RGB")
    return title_screen(w, h).convert("RGB")


def top_shelf(w, h):
    """The static Top Shelf image. tvOS shows it as a band across the top of
    the screen, so it's the top of the title screen. With --key-art the key
    art is cropped so the logo fits in the sky above the characters."""
    if has_key_art():
        art = img("MC_key_art.png")
        art = art.resize((w, round(art.height * w / art.width)), Image.LANCZOS)
        top = min(max(0, round(art.height * 0.33 - h * 0.42)), art.height - h)
        band = art.crop((0, top, w, top + h))
        return with_logo(band, h * 0.78, round(h * 0.05)).convert("RGB")
    return title_screen(w, round(w * 9 / 16)).crop((0, 0, w, h)).convert("RGB")


def write_top_shelf(name, w1, h1):
    d = os.path.join(BRAND, name + ".imageset")
    os.makedirs(d, exist_ok=True)
    images = []
    for k, suffix, tag in ((1, "", "1x"), (2, "@2x", "2x")):
        fname = "topshelf%s%s.png" % ("-wide" if "Wide" in name else "", suffix)
        top_shelf(w1 * k, h1 * k).save(os.path.join(d, fname))
        images.append({"filename": fname, "idiom": "tv", "scale": tag})
    write_json(os.path.join(d, "Contents.json"), {"images": images, "info": INFO})


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    version = args[0] if args else "26.3"
    sources(version)
    shutil.rmtree(BRAND, ignore_errors=True)
    write_json(os.path.join(XCASSETS, "Contents.json"), {"info": INFO})
    write_json(os.path.join(BRAND, "Contents.json"), {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})
    write_imagestack("App Icon", (((400, 240), "", "1x"), ((800, 480), "@2x", "2x")))
    write_imagestack("App Icon - App Store", (((1280, 768), "", "1x"),))
    write_top_shelf("Top Shelf Image", 1920, 720)
    write_top_shelf("Top Shelf Image Wide", 2320, 720)
    os.makedirs(HERO, exist_ok=True)
    hero(1920, 1080).save(os.path.join(HERO, "hero.jpg"), quality=90)
    hero(3840, 2160).save(os.path.join(HERO, "hero@2x.jpg"), quality=90)
    print("[art] wrote %s" % os.path.relpath(HERO, ROOT))
    print("[art] wrote %s" % os.path.relpath(BRAND, ROOT))
    with open(os.path.join(ROOT, "build", "art-made-for"), "w") as f:
        f.write(version + (" key-art" if USE_KEY_ART else "") + "\n")


if __name__ == "__main__":
    main()
