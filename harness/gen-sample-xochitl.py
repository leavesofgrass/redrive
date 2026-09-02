#!/usr/bin/env python3
"""
gen-sample-xochitl.py - write a realistic reMarkable 3.x xochitl directory for the
redrive fake-tablet harness. Standard library only (Python 3.11+), deterministic for a
given --seed, ASCII-only source (the one non-ASCII title is built from UTF-8 bytes).

  full run:            gen-sample-xochitl.py --root DIR --profile paperpro-3.27 [--legacy]
  system files only:   gen-sample-xochitl.py --root DIR --profile rm2-3.11 --system-files-only
  fetch fixtures only: gen-sample-xochitl.py --fetch-only --fixtures DIR

Sample entities (titles -> uuids are written to the manifest):
  folder   Work                     (root)
  folder   Projects                 (parent Work)
  pdf      Quarterly Report         (3 pages, parent Projects; pages 1 and 3 have real v6 ink,
                                     page 2 is the zero-byte .rm that 3.x writes for untouched pages)
  epub     Sample Book              (root; minimal valid EPUB, stored "mimetype" first)
  notebook Meeting notes            (root; 2 pages of real v6 ink, no PDF, .local file)
  pdf      Old draft                (parent "trash")
  pdf      NON_ASCII_TITLE          (root; 1 page; "Resume" with accents, an em dash, Japanese
                                     and a check mark - see the manifest; no annotations)
"""
import argparse
import io
import json
import os
import random
import sys
import urllib.request
import uuid
import zipfile
from datetime import datetime, timezone

RM_FIXTURES = ["Normal_AB.rm", "Lines_v2.rm", "Bold_Heading_Bullet_Normal.rm", "Normal_A_stroke_2_layers.rm"]
FIXTURE_URL = "https://raw.githubusercontent.com/ricklupton/rmscene/main/tests/data/"
RM_V6_HEADER = b"reMarkable .lines file, version=6" + b" " * 10  # 43 bytes, as the device writes it
# "Resume" (e-acute x2), em dash, Japanese "nihongo", check mark - kept as UTF-8 bytes so the source stays ASCII.
NON_ASCII_TITLE = (b"R\xc3\xa9sum\xc3\xa9 \xe2\x80\x94 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xe2\x9c\x93").decode("utf-8")
BASE_MS = int(datetime(2026, 9, 1, 14, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)
MIN = 60 * 1000
DEFAULT_SEED = 20260901

PROFILES = {
    "paperpro-3.27": {
        "model": "reMarkable Paper Pro",
        "version": "3.27.3.5",
        "machine": "ferrari",
        "etc_version": "20250812134705",
        "os_release": "remarkable",
        "update_conf": False,
    },
    "rm2-3.11": {
        "model": "reMarkable 2",
        "version": "3.11.2.5",
        "machine": "rm2",
        "etc_version": "20240311110322",
        "os_release": "codex",
        "update_conf": True,
    },
}


# ----------------------------------------------------------------------------- helpers
def write_json(path, obj):
    # xochitl writes pretty-printed JSON with sorted keys (Qt's QJsonDocument), UTF-8.
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(obj, ensure_ascii=False, indent=4, sort_keys=True))
        f.write("\n")


def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def make_uuid(rng):
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def idx_value(i):
    # CRDT ordering strings as xochitl 3.x generates them for consecutive pages.
    return "b" + chr(ord("a") + i)


# ----------------------------------------------------------------------------- PDF / EPUB
def make_pdf(texts):
    """Minimal valid PDF: one US-Letter page per text string, Helvetica, correct xref."""
    n = len(texts)
    page_ids = [4 + 2 * i for i in range(n)]
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join("%d 0 R" % p for p in page_ids)
    objs.append(("<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, n)).encode("ascii"))
    objs.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    for i, text in enumerate(texts):
        esc = text.encode("ascii", "replace")
        esc = esc.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")
        stream = b"BT /F1 24 Tf 72 720 Td (" + esc + b") Tj ET"
        objs.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                     "/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>" % (page_ids[i] + 1)).encode("ascii"))
        objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for num, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % num + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return bytes(out)


def make_epub(title, author, chapters):
    """Minimal valid EPUB 3 (with an EPUB 2 NCX for old readers): stored mimetype first."""
    container = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
                 '  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\n'
                 '</container>\n')
    manifest_items = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>']
    spine_items = []
    nav_points = []
    nav_list = []
    files = {}
    for i, (ctitle, paragraphs) in enumerate(chapters, start=1):
        name = "chapter%d.xhtml" % i
        body = "".join("<p>%s</p>\n" % p for p in paragraphs)
        files["OEBPS/" + name] = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                                  '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title></head>\n'
                                  '<body><h1>%s</h1>\n%s</body></html>\n' % (ctitle, ctitle, body))
        manifest_items.append('<item id="ch%d" href="%s" media-type="application/xhtml+xml"/>' % (i, name))
        spine_items.append('<itemref idref="ch%d"/>' % i)
        nav_points.append('<navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/></navPoint>'
                          % (i, i, ctitle, name))
        nav_list.append('<li><a href="%s">%s</a></li>' % (name, ctitle))
    opf = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">\n'
           '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
           '    <dc:identifier id="bookid">urn:uuid:5d9c2e7a-0d5c-4d2f-9d0e-0000fa4eb00c</dc:identifier>\n'
           '    <dc:title>%s</dc:title>\n    <dc:creator>%s</dc:creator>\n    <dc:language>en</dc:language>\n'
           '    <meta property="dcterms:modified">2026-09-01T14:00:00Z</meta>\n'
           '  </metadata>\n  <manifest>\n    %s\n  </manifest>\n  <spine toc="ncx">\n    %s\n  </spine>\n</package>\n'
           % (title, author, "\n    ".join(manifest_items), "\n    ".join(spine_items)))
    ncx = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
           '  <head><meta name="dtb:uid" content="urn:uuid:5d9c2e7a-0d5c-4d2f-9d0e-0000fa4eb00c"/></head>\n'
           '  <docTitle><text>%s</text></docTitle>\n  <navMap>%s</navMap>\n</ncx>\n' % (title, "".join(nav_points)))
    nav = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>%s</title></head>\n'
           '<body><nav epub:type="toc"><ol>%s</ol></nav></body></html>\n' % (title, "".join(nav_list)))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        info = zipfile.ZipInfo("mimetype")
        info.compress_type = zipfile.ZIP_STORED
        z.writestr(info, "application/epub+zip")
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        for name, text in files.items():
            z.writestr(name, text, compress_type=zipfile.ZIP_DEFLATED)
    return buf.getvalue()


# ----------------------------------------------------------------------------- fixtures
def fetch_fixtures(fixdir, download=True, placeholders=True):
    """Ensure the four v6 .rm fixtures exist. Returns {name: present|downloaded|placeholder|missing}."""
    status = {}
    os.makedirs(fixdir, exist_ok=True)
    for name in RM_FIXTURES:
        path = os.path.join(fixdir, name)
        if os.path.isfile(path) and os.path.getsize(path) > len(RM_V6_HEADER):
            status[name] = "present"
            continue
        if download:
            try:
                with urllib.request.urlopen(FIXTURE_URL + name, timeout=20) as r:
                    data = r.read()
                if not data.startswith(b"reMarkable .lines file"):
                    raise ValueError("not a .lines file")
                write_bytes(path, data)
                status[name] = "downloaded"
                print("fixture downloaded: %s (%d bytes)" % (name, len(data)))
                continue
            except Exception as e:  # noqa: BLE001 - report and fall back
                print("fixture download failed: %s: %s" % (name, e), file=sys.stderr)
        if placeholders:
            write_bytes(path, RM_V6_HEADER)
            status[name] = "placeholder"
            print("fixture placeholder written (43-byte v6 header only): %s" % name, file=sys.stderr)
        else:
            status[name] = "missing"
    return status


def read_fixture(fixdir, name):
    path = os.path.join(fixdir, name)
    if os.path.isfile(path):
        with open(path, "rb") as f:
            return f.read()
    return RM_V6_HEADER


# ----------------------------------------------------------------------------- xochitl shapes
def metadata(name, parent, typ, created, modified, page=0, pinned=False, legacy=False):
    md = {
        "createdTime": str(created),
        "lastModified": str(modified),
        "parent": parent,
        "pinned": pinned,
        "type": typ,
        "visibleName": name,
    }
    if typ == "DocumentType":
        md["lastOpened"] = str(modified)
        md["lastOpenedPage"] = page
    if legacy:
        md.update({"deleted": False, "metadatamodified": False, "modified": False, "synced": True, "version": 1})
    return md


def content(file_type, doc_uuid, page_ids, original_count, size_bytes, redir=True):
    pages = []
    for i, pid in enumerate(page_ids):
        p = {
            "id": pid,
            "idx": {"timestamp": "1:2", "value": idx_value(i)},
            "template": {"timestamp": "1:1", "value": "Blank"},
        }
        if redir:
            p["redir"] = {"timestamp": "1:2", "value": i}
        pages.append(p)
    return {
        "cPages": {
            "lastOpened": {"timestamp": "1:1", "value": None},
            "original": {"timestamp": "1:1", "value": original_count},
            "pages": pages,
            "uuids": [{"first": doc_uuid, "second": 1}],
        },
        "coverPageNumber": 0,
        "documentMetadata": {},
        "extraMetadata": {},
        "fileType": file_type,
        "fontName": "",
        "formatVersion": 2,
        "lineHeight": -1,
        "margins": 125,
        "orientation": "portrait",
        "originalPageCount": original_count,
        "pageCount": len(page_ids),
        "pageTags": [],
        "sizeInBytes": str(size_bytes),
        "tags": [],
        "textAlignment": "justify",
        "textScale": 1,
        "transform": {"m11": 1, "m12": 0, "m13": 0, "m21": 0, "m22": 1, "m23": 0, "m31": 0, "m32": 0, "m33": 1},
        "zoomMode": "bestFit",
    }


def write_page_dir(root, doc_uuid, page_ids, ink):
    """ink: {page_uuid: bytes|None}. None or b"" writes the zero-byte .rm 3.x leaves for untouched pages."""
    d = os.path.join(root, doc_uuid)
    os.makedirs(d, exist_ok=True)
    for pid in page_ids:
        data = ink.get(pid)
        if data:
            write_bytes(os.path.join(d, pid + ".rm"), data)
            write_json(os.path.join(d, pid + "-metadata.json"), {"layers": [{"name": "Layer 1"}]})
        else:
            write_bytes(os.path.join(d, pid + ".rm"), b"")


# ----------------------------------------------------------------------------- sample set
def generate(root, fixdir, legacy, rng):
    os.makedirs(root, exist_ok=True)
    entries = []

    def add(title, doc_uuid, typ, parent, parent_title, file_type=None, pages=None):
        entries.append({
            "title": title, "uuid": doc_uuid, "type": typ, "parent": parent,
            "parentTitle": parent_title, "fileType": file_type, "pages": pages or [],
        })

    def folder(title, parent, parent_title, created):
        u = make_uuid(rng)
        write_json(os.path.join(root, u + ".metadata"),
                   metadata(title, parent, "CollectionType", created, created + MIN, legacy=legacy))
        write_json(os.path.join(root, u + ".content"), {"tags": []})
        add(title, u, "CollectionType", parent, parent_title)
        return u

    work = folder("Work", "", "", BASE_MS - 10 * 24 * 60 * MIN)
    projects = folder("Projects", work, "Work", BASE_MS - 9 * 24 * 60 * MIN)

    # --- Quarterly Report: 3-page PDF, ink on pages 1 and 3, zero-byte .rm on page 2
    u = make_uuid(rng)
    pids = [make_uuid(rng) for _ in range(3)]
    pdf = make_pdf(["Quarterly Report - page %d of 3" % (i + 1) for i in range(3)])
    write_bytes(os.path.join(root, u + ".pdf"), pdf)
    write_json(os.path.join(root, u + ".metadata"),
               metadata("Quarterly Report", projects, "DocumentType", BASE_MS - 3 * 24 * 60 * MIN, BASE_MS - 30 * MIN,
                        page=2, legacy=legacy))
    write_json(os.path.join(root, u + ".content"), content("pdf", u, pids, 3, len(pdf)))
    write_text(os.path.join(root, u + ".pagedata"), "Blank\n" * 3)
    ink = {pids[0]: read_fixture(fixdir, "Normal_AB.rm"), pids[1]: None, pids[2]: read_fixture(fixdir, "Lines_v2.rm")}
    write_page_dir(root, u, pids, ink)
    add("Quarterly Report", u, "DocumentType", projects, "Projects", "pdf",
        [{"id": pids[0], "rm": "Normal_AB.rm"}, {"id": pids[1], "rm": "empty"}, {"id": pids[2], "rm": "Lines_v2.rm"}])

    # --- Sample Book: EPUB at root (paginated as if it had been opened once, no ink)
    u = make_uuid(rng)
    epub = make_epub("Sample Book", "redrive harness",
                     [("Chapter One", ["It was a fake tablet, and the ink was imaginary.", "The end of chapter one."]),
                      ("Chapter Two", ["The second chapter is just as short.", "Nothing to annotate here."])])
    write_bytes(os.path.join(root, u + ".epub"), epub)
    pids = [make_uuid(rng) for _ in range(4)]
    write_json(os.path.join(root, u + ".metadata"),
               metadata("Sample Book", "", "DocumentType", BASE_MS - 5 * 24 * 60 * MIN, BASE_MS - 2 * 24 * 60 * MIN,
                        legacy=legacy))
    c = content("epub", u, pids, -1, len(epub), redir=False)
    c["coverPageNumber"] = -1
    write_json(os.path.join(root, u + ".content"), c)
    write_text(os.path.join(root, u + ".pagedata"), "Blank\n" * 4)
    os.makedirs(os.path.join(root, u), exist_ok=True)
    add("Sample Book", u, "DocumentType", "", "", "epub", [{"id": p, "rm": "none"} for p in pids])

    # --- Meeting notes: native notebook, 2 pages of real ink, no PDF
    u = make_uuid(rng)
    pids = [make_uuid(rng) for _ in range(2)]
    ink = {pids[0]: read_fixture(fixdir, "Bold_Heading_Bullet_Normal.rm"),
           pids[1]: read_fixture(fixdir, "Normal_A_stroke_2_layers.rm")}
    write_json(os.path.join(root, u + ".metadata"),
               metadata("Meeting notes", "", "DocumentType", BASE_MS - 24 * 60 * MIN, BASE_MS - 5 * MIN, page=1,
                        legacy=legacy))
    write_json(os.path.join(root, u + ".content"),
               content("notebook", u, pids, -1, sum(len(v) for v in ink.values()), redir=False))
    write_text(os.path.join(root, u + ".pagedata"), "Blank\n" * 2)
    write_json(os.path.join(root, u + ".local"), {"contentFormatVersion": 2})
    write_page_dir(root, u, pids, ink)
    add("Meeting notes", u, "DocumentType", "", "", "notebook",
        [{"id": pids[0], "rm": "Bold_Heading_Bullet_Normal.rm"}, {"id": pids[1], "rm": "Normal_A_stroke_2_layers.rm"}])

    # --- Old draft: trashed PDF
    u = make_uuid(rng)
    pids = [make_uuid(rng)]
    pdf = make_pdf(["Old draft - superseded"])
    write_bytes(os.path.join(root, u + ".pdf"), pdf)
    write_json(os.path.join(root, u + ".metadata"),
               metadata("Old draft", "trash", "DocumentType", BASE_MS - 20 * 24 * 60 * MIN, BASE_MS - 6 * 24 * 60 * MIN,
                        legacy=legacy))
    write_json(os.path.join(root, u + ".content"), content("pdf", u, pids, 1, len(pdf)))
    write_text(os.path.join(root, u + ".pagedata"), "Blank\n")
    write_page_dir(root, u, pids, {pids[0]: None})
    add("Old draft", u, "DocumentType", "trash", "trash", "pdf", [{"id": pids[0], "rm": "empty"}])

    # --- non-ASCII title: 1-page PDF at root, untouched
    u = make_uuid(rng)
    pids = [make_uuid(rng)]
    pdf = make_pdf(["Resume (the non-ASCII title lives in .metadata)"])
    write_bytes(os.path.join(root, u + ".pdf"), pdf)
    write_json(os.path.join(root, u + ".metadata"),
               metadata(NON_ASCII_TITLE, "", "DocumentType", BASE_MS - 2 * 24 * 60 * MIN, BASE_MS - 60 * MIN,
                        legacy=legacy))
    write_json(os.path.join(root, u + ".content"), content("pdf", u, pids, 1, len(pdf)))
    write_text(os.path.join(root, u + ".pagedata"), "Blank\n")
    write_page_dir(root, u, pids, {pids[0]: None})
    add(NON_ASCII_TITLE, u, "DocumentType", "", "", "pdf", [{"id": pids[0], "rm": "empty"}])

    return entries


def scan_entries(root):
    """Rebuild manifest entries from an existing xochitl directory."""
    entries = []
    if not os.path.isdir(root):
        return entries
    by_uuid = {}
    for name in sorted(os.listdir(root)):
        if not name.endswith(".metadata"):
            continue
        u = name[:-len(".metadata")]
        try:
            with open(os.path.join(root, name), encoding="utf-8") as f:
                md = json.load(f)
        except Exception:  # noqa: BLE001
            continue
        if isinstance(md, dict):
            by_uuid[u] = md
    for u, md in by_uuid.items():
        c = {}
        cpath = os.path.join(root, u + ".content")
        if os.path.isfile(cpath):
            try:
                with open(cpath, encoding="utf-8") as f:
                    c = json.load(f)
            except Exception:  # noqa: BLE001
                c = {}
        if not isinstance(c, dict):
            c = {}
        pages = []
        for p in ((c.get("cPages") or {}).get("pages") or []):
            pid = p.get("id")
            rm = os.path.join(root, u, str(pid) + ".rm")
            if not os.path.isfile(rm):
                kind = "none"
            elif os.path.getsize(rm) == 0:
                kind = "empty"
            else:
                kind = "ink"
            pages.append({"id": pid, "rm": kind})
        parent = md.get("parent", "")
        entries.append({
            "title": md.get("visibleName", ""), "uuid": u, "type": md.get("type", ""), "parent": parent,
            "parentTitle": (by_uuid.get(parent, {}).get("visibleName", parent) if parent else ""),
            "fileType": c.get("fileType") if md.get("type") == "DocumentType" else None, "pages": pages,
        })
    entries.sort(key=lambda e: (e["type"] != "CollectionType", e["title"].lower()))
    return entries


# ----------------------------------------------------------------------------- system files
def write_system_files(profile_name, conf_path, etc_dir="/etc", usr_share="/usr/share/remarkable"):
    p = PROFILES[profile_name]
    os.makedirs(etc_dir, exist_ok=True)
    write_text(os.path.join(etc_dir, "version"), p["etc_version"] + "\n")
    osr = os.path.join(etc_dir, "os-release")
    if os.path.islink(osr):
        os.unlink(osr)
    if p["os_release"] == "remarkable":
        write_text(osr, "".join(line + "\n" for line in [
            'ID=remarkable',
            'NAME="reMarkable Linux"',
            'VERSION="%s"' % p["version"],
            'VERSION_ID=%s' % p["version"],
            'PRETTY_NAME="reMarkable Linux %s"' % p["version"],
            'IMG_VERSION=%s' % p["version"],
            'IMG_COMMIT=6f2b1c9e3a4d5f60',
            'BUILD_ID=%s' % p["etc_version"],
            'MACHINE=%s' % p["machine"],
            'HOME_URL="https://remarkable.com/"',
            'FAKE_TABLET=1',
        ]))
    else:
        write_text(osr, "".join(line + "\n" for line in [
            'ID="codex"',
            'NAME="Codex Linux"',
            'VERSION="%s"' % p["version"],
            'VERSION_ID="%s"' % p["version"],
            'PRETTY_NAME="Codex Linux %s (%s)"' % (p["version"], p["model"]),
            'MACHINE=%s' % p["machine"],
            'FAKE_TABLET=1',
        ]))
    if p["update_conf"]:
        os.makedirs(usr_share, exist_ok=True)
        write_text(os.path.join(usr_share, "update.conf"), "".join(line + "\n" for line in [
            "[General]",
            "#REMARKABLE_RELEASE_APPID={98DA7DF2-4E3E-4744-9DE6-EC931886ABAB}",
            "#SERVER=https://updates.cloud.remarkable.engineering/service/update2",
            "#GROUP=Prod",
            "#PLATFORM=reMarkable2",
            "REMARKABLE_RELEASE_VERSION=%s" % p["version"],
        ]))
    else:
        old = os.path.join(usr_share, "update.conf")
        if os.path.isfile(old):
            os.unlink(old)
    write_xochitl_conf(conf_path)


def write_xochitl_conf(path):
    """Ensure [General] carries DeveloperPassword=fake and WebInterfaceEnabled=true, keeping other lines."""
    wanted = [("DeveloperPassword", "fake"), ("WebInterfaceEnabled", "true")]
    lines = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    stripped = [ln.strip() for ln in lines]
    if "[General]" not in stripped:
        lines = ["[General]"] + lines
        stripped = [ln.strip() for ln in lines]
    start = stripped.index("[General]")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].strip().startswith("["):
            end = i
            break
    for key, value in wanted:
        found = False
        for i in range(start + 1, end):
            if lines[i].split("=", 1)[0].strip() == key:
                lines[i] = "%s=%s" % (key, value)
                found = True
        if not found:
            lines.insert(start + 1, "%s=%s" % (key, value))
            end += 1
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text(path, "\n".join(lines) + "\n")


# ----------------------------------------------------------------------------- main
def default_fixture_dir():
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "rm")
    for cand in ("/opt/fake-tablet/fixtures/rm", here):
        if os.path.isdir(cand):
            return cand
    return here


def default_manifest_path(root):
    if os.path.isdir("/opt/fake-tablet"):
        return "/opt/fake-tablet/manifest.json"
    return os.path.join(os.path.dirname(os.path.abspath(root.rstrip("/\\"))), "manifest.json")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate a sample reMarkable 3.x xochitl directory.")
    ap.add_argument("--root", help="xochitl directory to write")
    ap.add_argument("--profile", default=os.environ.get("FAKE_PROFILE", "paperpro-3.27"), choices=sorted(PROFILES))
    ap.add_argument("--legacy", action="store_true", help="add deleted/metadatamodified/modified/synced/version to .metadata")
    ap.add_argument("--system-files-only", action="store_true",
                    help="only write /etc/version, os-release or update.conf, xochitl.conf and refresh the manifest")
    ap.add_argument("--fetch-only", action="store_true", help="only download missing .rm fixtures into --fixtures")
    ap.add_argument("--fixtures", default=None, help="directory holding the v6 .rm fixtures")
    ap.add_argument("--manifest", default=None, help="where to write manifest.json")
    ap.add_argument("--conf", default="/home/root/.config/remarkable/xochitl.conf")
    ap.add_argument("--etc", default="/etc", help="directory for version/os-release (tests can redirect)")
    ap.add_argument("--usr-share", default="/usr/share/remarkable")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED, help="0 = random uuids")
    ap.add_argument("--no-download", action="store_true", help="never download fixtures; use placeholders")
    ap.add_argument("--no-system-files", action="store_true", help="skip /etc and xochitl.conf (host-side runs)")
    args = ap.parse_args(argv)

    fixdir = args.fixtures or default_fixture_dir()
    if args.fetch_only:
        status = fetch_fixtures(fixdir, download=True, placeholders=False)
        print(json.dumps(status))
        return 0

    if not args.root:
        ap.error("--root is required")
    root = args.root
    manifest_path = args.manifest or default_manifest_path(root)

    manifest = {}
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path, encoding="utf-8") as f:
                manifest = json.load(f)
        except Exception:  # noqa: BLE001
            manifest = {}
    if not isinstance(manifest, dict):
        manifest = {}

    if args.system_files_only:
        if not args.no_system_files:
            write_system_files(args.profile, args.conf, args.etc, args.usr_share)
        entries = scan_entries(root)
        manifest.update({
            "profile": args.profile, "root": root,
            "titles": {e["title"]: e["uuid"] for e in entries}, "entries": entries,
        })
        manifest.setdefault("fixtures", {})
        write_json(manifest_path, manifest)
        print("system files written for profile %s; manifest refreshed (%d entries) at %s"
              % (args.profile, len(entries), manifest_path))
        return 0

    rng = random.Random(args.seed) if args.seed else random.Random()
    fixture_status = fetch_fixtures(fixdir, download=not args.no_download, placeholders=True)
    entries = generate(root, fixdir, args.legacy, rng)
    if not args.no_system_files:
        write_system_files(args.profile, args.conf, args.etc, args.usr_share)
    manifest = {
        "profile": args.profile,
        "root": root,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seed": args.seed,
        "legacy": args.legacy,
        "fixtures": fixture_status,
        "titles": {e["title"]: e["uuid"] for e in entries},
        "entries": entries,
    }
    write_json(manifest_path, manifest)
    print(json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True))
    if any(v == "placeholder" for v in fixture_status.values()):
        print("NOTE: one or more .rm files are 43-byte placeholders (fixture download failed).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
