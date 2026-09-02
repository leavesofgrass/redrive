#!/usr/bin/env python3
"""
mock-webui.py - imitation of the reMarkable USB web interface as measured on firmware
3.27, for the redrive fake-tablet harness. Standard library only.

Endpoints (the HTTP method is ignored unless noted):
  /documents/            JSON array of root entries
  /documents/{id}        children of folder {id}; a non-folder id returns the ROOT listing (quirk)
  /upload                POST multipart, one part named "file" -> 201 {"status":"Upload successful"}
  /download/{id}/pdf     stored PDF, or a generated stand-in for notebooks / EPUBs
  /download/{id}/placeholder  400 {"error":"Filetype not supported"} unless FAKE_LEGACY_PLACEHOLDER=1
  /download/{id}/rmdoc   zip of {id}.metadata, {id}.content, {id}/*.rm and the .pdf/.epub
  /thumbnail/{id}        a tiny PNG served as image/jpeg (as the device does)
  /log.txt               /home/root/log.txt
  anything else          500 {"error":"Unknown file"}

Quirks reproduced: "charset=ISO-8859-1" on UTF-8 JSON, "Connection: close", VissibleName,
uploads land at root with the filename verbatim as the title, catalog reloaded only on
(re)start unless FAKE_LIVE_SCAN=1.

Flags (environment): FAKE_LIVE_SCAN, FAKE_STRIP_EXT, FAKE_UPLOAD_USES_LAST_FOLDER,
FAKE_RMDOC_HONORS_PARENT, FAKE_DUAL_FRAMING, FAKE_LEGACY_PLACEHOLDER, FAKE_IGNORE_CONF,
FAKE_BIND (default 10.11.99.1), FAKE_WEB_PORT (default 80).
"""
import io
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import uuid
import zipfile
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

XDIR = os.environ.get("FAKE_XOCHITL_DIR", "/home/root/.local/share/remarkable/xochitl")
LOG_PATH = os.environ.get("FAKE_LOG", "/home/root/log.txt")
CONF_PATH = os.environ.get("FAKE_XOCHITL_CONF", "/home/root/.config/remarkable/xochitl.conf")
PID_PATH = os.environ.get("FAKE_PID_FILE", "/run/fake-xochitl.pid")
PORT = int(os.environ.get("FAKE_WEB_PORT", "80"))
PRIMARY_BIND = os.environ.get("FAKE_BIND", "10.11.99.1")
MAX_UPLOAD = 100 * 1024 * 1024
JSON_CTYPE = "application/json; charset=ISO-8859-1"


def flag(name):
    return os.environ.get(name, "0").strip().lower() in ("1", "true", "yes", "on")


LIVE_SCAN = flag("FAKE_LIVE_SCAN")
STRIP_EXT = flag("FAKE_STRIP_EXT")
USE_LAST_FOLDER = flag("FAKE_UPLOAD_USES_LAST_FOLDER")
RMDOC_HONORS_PARENT = flag("FAKE_RMDOC_HONORS_PARENT")
DUAL_FRAMING = flag("FAKE_DUAL_FRAMING")
LEGACY_PLACEHOLDER = flag("FAKE_LEGACY_PLACEHOLDER")
IGNORE_CONF = flag("FAKE_IGNORE_CONF")

_log_lock = threading.Lock()


def log(msg):
    line = "%s webui: %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    with _log_lock:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass
        sys.stderr.write(line)
        sys.stderr.flush()


# ----------------------------------------------------------------------------- small helpers
def now_ms():
    return int(time.time() * 1000)


def iso_from_ms(ms):
    try:
        ms = int(ms)
    except (TypeError, ValueError):
        ms = 0
    dt = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ms % 1000)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(obj, ensure_ascii=False, indent=4, sort_keys=True))
        f.write("\n")


def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)


def ascii_name(text, fallback="document"):
    s = text.encode("ascii", "replace").decode("ascii").replace('"', "'").replace("\\", "_")
    s = s.strip() or fallback
    return s


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
        stream = b"BT /F1 18 Tf 72 720 Td (" + esc + b") Tj ET"
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


def tiny_png(w=32, h=32, gray=200):
    raw = b"".join(b"\x00" + bytes([gray]) * w for _ in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


THUMB_PNG = tiny_png()


def count_pdf_pages(data):
    n = len(re.findall(rb"/Type\s*/Page(?![A-Za-z])", data))
    return n if n > 0 else 1


def idx_value(i):
    return "b" + chr(ord("a") + (i % 26))


def content_shape(file_type, doc_uuid, page_ids, original_count, size_bytes, redir):
    pages = []
    for i, pid in enumerate(page_ids):
        p = {"id": pid, "idx": {"timestamp": "1:2", "value": idx_value(i)},
             "template": {"timestamp": "1:1", "value": "Blank"}}
        if redir:
            p["redir"] = {"timestamp": "1:2", "value": i}
        pages.append(p)
    return {
        "cPages": {"lastOpened": {"timestamp": "1:1", "value": None},
                   "original": {"timestamp": "1:1", "value": original_count},
                   "pages": pages, "uuids": [{"first": doc_uuid, "second": 1}]},
        "coverPageNumber": 0 if file_type == "pdf" else -1,
        "documentMetadata": {}, "extraMetadata": {}, "fileType": file_type, "fontName": "",
        "formatVersion": 2, "lineHeight": -1, "margins": 125, "orientation": "portrait",
        "originalPageCount": original_count, "pageCount": len(page_ids), "pageTags": [],
        "sizeInBytes": str(size_bytes), "tags": [], "textAlignment": "justify", "textScale": 1,
        "transform": {"m11": 1, "m12": 0, "m13": 0, "m21": 0, "m22": 1, "m23": 0, "m31": 0, "m32": 0, "m33": 1},
        "zoomMode": "bestFit",
    }


# ----------------------------------------------------------------------------- multipart
def parse_multipart(body, ctype):
    m = re.search(r'boundary="?([^";]+)"?', ctype or "")
    if not m:
        return []
    delim = b"--" + m.group(1).encode("latin-1")
    parts = []
    for seg in body.split(delim)[1:]:
        if seg.startswith(b"--"):
            break
        if seg.startswith(b"\r\n"):
            seg = seg[2:]
        elif seg.startswith(b"\n"):
            seg = seg[1:]
        head, sep, data = seg.partition(b"\r\n\r\n")
        if not sep:
            head, sep, data = seg.partition(b"\n\n")
            if not sep:
                continue
        if data.endswith(b"\r\n"):
            data = data[:-2]
        elif data.endswith(b"\n"):
            data = data[:-1]
        headers = {}
        for line in head.decode("utf-8", "replace").splitlines():
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        cd = headers.get("content-disposition", "")
        name = re.search(r'(?:^|;)\s*name="([^"]*)"', cd)
        filename = None
        ext = re.search(r"filename\*=(?:UTF-8|utf-8)''([^;]+)", cd)
        if ext:
            filename = urllib.parse.unquote(ext.group(1))
        else:
            fn = re.search(r'filename="([^"]*)"', cd)
            if fn:
                filename = fn.group(1)
        parts.append({"name": name.group(1) if name else "", "filename": filename,
                      "content_type": headers.get("content-type", ""), "data": data})
    return parts


def sniff_kind(data, filename, ctype):
    ext = os.path.splitext(filename or "")[1].lower()
    if data.startswith(b"%PDF"):
        return "pdf"
    if data.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                names = z.namelist()
                if "mimetype" in names and b"epub" in z.read("mimetype"):
                    return "epub"
                if any(n.endswith(".metadata") and "/" not in n for n in names):
                    return "rmdoc"
                if ext == ".rmdoc":
                    return "rmdoc"
                if ext == ".epub" or any(n.startswith("META-INF/") for n in names):
                    return "epub"
        except zipfile.BadZipFile:
            return None
        return None
    if ext == ".pdf" or ctype == "application/pdf":
        return "pdf"
    if ext == ".epub" or ctype == "application/epub+zip":
        return "epub"
    return None


# ----------------------------------------------------------------------------- catalog
class Catalog:
    def __init__(self, root):
        self.root = root
        self.lock = threading.RLock()
        self.docs = {}
        self.last_folder = ""

    def scan(self):
        docs = {}
        try:
            names = sorted(os.listdir(self.root))
        except OSError as e:
            log("scan failed: %s" % e)
            names = []
        for name in names:
            if not name.endswith(".metadata"):
                continue
            uid = name[:-len(".metadata")]
            md = read_json(os.path.join(self.root, name))
            if not isinstance(md, dict):
                log("skipping unreadable %s" % name)
                continue
            c = read_json(os.path.join(self.root, uid + ".content"))
            docs[uid] = {"metadata": md, "content": c if isinstance(c, dict) else {}}
        with self.lock:
            self.docs = docs
        log("catalog: %d item(s) loaded from %s" % (len(docs), self.root))

    def get(self, uid):
        with self.lock:
            return self.docs.get(uid)

    def add(self, uid, md, c):
        with self.lock:
            self.docs[uid] = {"metadata": md, "content": c or {}}

    @staticmethod
    def visible(rec):
        md = rec["metadata"]
        return not md.get("deleted") and md.get("parent", "") != "trash"

    def is_folder(self, uid):
        rec = self.get(uid)
        return bool(rec) and rec["metadata"].get("type") == "CollectionType" and self.visible(rec)

    def listing(self, parent):
        with self.lock:
            items = [(uid, rec) for uid, rec in self.docs.items()
                     if self.visible(rec) and rec["metadata"].get("parent", "") == parent]
        entries = [entry_for(uid, rec) for uid, rec in items]
        entries.sort(key=lambda e: e["VisibleName"].lower())
        return entries


def entry_for(uid, rec):
    md = rec["metadata"]
    c = rec["content"]
    is_doc = md.get("type", "DocumentType") == "DocumentType"
    name = md.get("visibleName", "")
    e = {"Bookmarked": bool(md.get("pinned", False))}
    if is_doc:
        try:
            e["CurrentPage"] = int(md.get("lastOpenedPage", 0) or 0)
        except (TypeError, ValueError):
            e["CurrentPage"] = 0
    e["ID"] = uid
    e["ModifiedClient"] = iso_from_ms(md.get("lastModified", 0))
    e["Parent"] = md.get("parent", "")
    e["Type"] = md.get("type", "DocumentType")
    e["VisibleName"] = name
    e["VissibleName"] = name
    if is_doc:
        e["fileType"] = c.get("fileType", "")
    return e


CATALOG = Catalog(XDIR)


# ----------------------------------------------------------------------------- document creation
def create_document(kind, data, filename, parent):
    title = filename
    if STRIP_EXT:
        title = re.sub(r"\.(pdf|epub)$", "", title, flags=re.IGNORECASE)
    uid = str(uuid.uuid4())
    ms = now_ms()
    if kind == "pdf":
        n = count_pdf_pages(data)
        original = n
        redir = True
    else:
        n = 0
        original = -1
        redir = False
    page_ids = [str(uuid.uuid4()) for _ in range(n)]
    c = content_shape(kind, uid, page_ids, original, len(data), redir)
    md = {"createdTime": str(ms), "lastModified": str(ms), "lastOpened": "0", "lastOpenedPage": 0,
          "parent": parent, "pinned": False, "type": "DocumentType", "visibleName": title}
    write_bytes(os.path.join(XDIR, uid + "." + kind), data)
    write_json(os.path.join(XDIR, uid + ".content"), c)
    if n:
        with open(os.path.join(XDIR, uid + ".pagedata"), "w", encoding="utf-8", newline="\n") as f:
            f.write("Blank\n" * n)
    os.makedirs(os.path.join(XDIR, uid), exist_ok=True)
    write_json(os.path.join(XDIR, uid + ".metadata"), md)
    CATALOG.add(uid, md, c)
    return uid, title


def import_rmdoc(data, filename, default_parent):
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        top_md = [n for n in names if n.endswith(".metadata") and "/" not in n]
        if not top_md:
            return None
        old = top_md[0][:-len(".metadata")]
        try:
            md = json.loads(z.read(top_md[0]).decode("utf-8"))
        except ValueError:
            return None
        if not isinstance(md, dict):
            return None
        title = md.get("visibleName") or filename
        parent = default_parent
        if RMDOC_HONORS_PARENT:
            p = md.get("parent", "")
            if p in ("", "trash") or CATALOG.is_folder(p):
                parent = p
        new = str(uuid.uuid4())
        page_map = {}
        for n in names:
            if n.startswith(old + "/"):
                base = n[len(old) + 1:]
                pid = None
                if base.endswith(".rm"):
                    pid = base[:-3]
                elif base.endswith("-metadata.json"):
                    pid = base[:-len("-metadata.json")]
                if pid and pid not in page_map:
                    page_map[pid] = str(uuid.uuid4())

        def rekey(text):
            text = text.replace(old, new)
            for a, b in page_map.items():
                text = text.replace(a, b)
            return text

        os.makedirs(os.path.join(XDIR, new), exist_ok=True)
        content_obj = {}
        for n in names:
            if n.endswith("/") or n == top_md[0]:
                continue
            blob = z.read(n)
            if n == old + ".content":
                text = rekey(blob.decode("utf-8", "replace"))
                try:
                    content_obj = json.loads(text)
                except ValueError:
                    content_obj = {}
                with open(os.path.join(XDIR, new + ".content"), "w", encoding="utf-8", newline="\n") as f:
                    f.write(text)
            elif n in (old + ".pdf", old + ".epub", old + ".pagedata", old + ".local"):
                write_bytes(os.path.join(XDIR, new + n[len(old):]), blob)
            elif n.startswith(old + "/"):
                write_bytes(os.path.join(XDIR, new, rekey(n[len(old) + 1:])), blob)
        if not isinstance(content_obj, dict):
            content_obj = {}
        ms = now_ms()
        new_md = {"createdTime": str(md.get("createdTime", ms)), "lastModified": str(ms), "lastOpened": "0",
                  "lastOpenedPage": 0, "parent": parent, "pinned": bool(md.get("pinned", False)),
                  "type": "DocumentType", "visibleName": title}
        write_json(os.path.join(XDIR, new + ".metadata"), new_md)
        CATALOG.add(new, new_md, content_obj)
        return new, title


def standin_pdf(uid, rec):
    title = rec["metadata"].get("visibleName", uid)
    d = os.path.join(XDIR, uid)
    rms = sorted(n for n in os.listdir(d) if n.endswith(".rm")) if os.path.isdir(d) else []
    n = len(rms)
    if n == 0:
        try:
            n = int(rec["content"].get("pageCount", 0) or 0)
        except (TypeError, ValueError):
            n = 0
        if n <= 0:
            n = 1
    return make_pdf(["fake-tablet render of %s - page %d of %d (no ink)" % (ascii_name(title), i + 1, n)
                     for i in range(n)])


def build_rmdoc(uid, rec):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for ext in (".metadata", ".content", ".pagedata", ".pdf", ".epub"):
            p = os.path.join(XDIR, uid + ext)
            if os.path.isfile(p):
                z.write(p, uid + ext)
        d = os.path.join(XDIR, uid)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                if name.endswith(".rm") or name.endswith("-metadata.json"):
                    z.write(os.path.join(d, name), uid + "/" + name)
    return buf.getvalue()


# ----------------------------------------------------------------------------- HTTP handler
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fake-tablet/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102 - own log
        pass

    def send_response(self, code, message=None):
        self._status = code
        super().send_response(code, message)

    def do_GET(self):
        self.dispatch()

    do_POST = do_GET
    do_PUT = do_GET
    do_DELETE = do_GET
    do_HEAD = do_GET
    do_OPTIONS = do_GET

    # --- plumbing
    def read_body(self):
        length = self.headers.get("Content-Length")
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if length:
            n = int(length)
            return self.rfile.read(n) if n > 0 else b""
        if "chunked" in te:
            buf = bytearray()
            while True:
                line = self.rfile.readline().strip()
                if not line:
                    break
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    while True:
                        trailer = self.rfile.readline()
                        if trailer in (b"\r\n", b"\n", b""):
                            break
                    break
                buf += self.rfile.read(size)
                self.rfile.readline()
            return bytes(buf)
        return b""

    def dispatch(self):
        self._status = 0
        self.body = b""
        try:
            self.body = self.read_body()
            if LIVE_SCAN:
                CATALOG.scan()
            self.route()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:  # noqa: BLE001
            log("error handling %s %s:\n%s" % (self.command, self.path, traceback.format_exc()))
            if not self._status:
                try:
                    self.send_json(500, {"error": "Unknown file"})
                except Exception:  # noqa: BLE001
                    pass
        finally:
            self.close_connection = True
            log("%s %s -> %s (%s)" % (self.command, self.path, self._status or "-", self.client_address[0]))

    def send_bytes(self, status, ctype, data, extra=None, dual=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Connection", "close")
        for k, v in (extra or []):
            self.send_header(k, v)
        if dual:
            # The real device sends both a Content-Length and chunked framing.
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if self.command != "HEAD":
                for i in range(0, len(data), 65536):
                    chunk = data[i:i + 65536]
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_bytes(status, JSON_CTYPE, data)

    # --- routing
    def route(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/documents", "/documents/"):
            return self.send_listing("")
        if path.startswith("/documents/"):
            fid = urllib.parse.unquote(path[len("/documents/"):]).strip("/")
            if CATALOG.is_folder(fid):
                return self.send_listing(fid)
            log("listing of non-folder id %r -> root listing (3.27 quirk)" % fid)
            return self.send_listing("")
        if path.rstrip("/") == "/upload":
            return self.handle_upload()
        m = re.match(r"^/download/([^/]+)/(pdf|placeholder|rmdoc)/?$", path)
        if m:
            return self.handle_download(urllib.parse.unquote(m.group(1)), m.group(2))
        m = re.match(r"^/thumbnail/([^/]+)/?$", path)
        if m:
            return self.handle_thumbnail(urllib.parse.unquote(m.group(1)))
        if path == "/log.txt":
            return self.handle_log()
        return self.send_json(500, {"error": "Unknown file"})

    def send_listing(self, parent):
        entries = CATALOG.listing(parent)
        CATALOG.last_folder = parent
        self.send_json(200, entries)

    def handle_upload(self):
        ctype = self.headers.get("Content-Type", "") or ""
        parts = parse_multipart(self.body, ctype) if "multipart/form-data" in ctype.lower() else []
        part = next((p for p in parts if p["name"] == "file"), None)
        if part is None or not part.get("filename"):
            return self.send_json(400, {"error": "No file sent"})
        data = part["data"]
        filename = part["filename"]
        if len(data) > MAX_UPLOAD:
            return self.send_json(400, {"error": "File too large"})
        kind = sniff_kind(data, filename, part.get("content_type", ""))
        if kind is None:
            return self.send_json(400, {"error": "Filetype not supported"})
        default_parent = CATALOG.last_folder if USE_LAST_FOLDER else ""
        if kind == "rmdoc":
            result = import_rmdoc(data, filename, default_parent)
            if result is None:
                return self.send_json(400, {"error": "Invalid rmdoc"})
        else:
            result = create_document(kind, data, filename, default_parent)
        uid, title = result
        log("upload: %s %r (%d bytes) -> %s parent=%r" % (kind, title, len(data), uid, default_parent))
        return self.send_json(201, {"status": "Upload successful"})

    def handle_download(self, uid, fmt):
        rec = CATALOG.get(uid)
        if rec is None or rec["metadata"].get("type") != "DocumentType":
            return self.send_json(500, {"error": "Unknown file"})
        if fmt == "placeholder" and not LEGACY_PLACEHOLDER:
            return self.send_json(400, {"error": "Filetype not supported"})
        name = ascii_name(rec["metadata"].get("visibleName", uid))
        if fmt == "rmdoc":
            data = build_rmdoc(uid, rec)
            return self.send_bytes(200, "application/zip", data,
                                   extra=[("Content-Disposition", 'attachment; filename="%s.rmdoc"' % name)],
                                   dual=DUAL_FRAMING)
        pdf_path = os.path.join(XDIR, uid + ".pdf")
        if os.path.isfile(pdf_path):
            with open(pdf_path, "rb") as f:
                data = f.read()
        else:
            data = standin_pdf(uid, rec)
        return self.send_bytes(200, "application/pdf", data,
                               extra=[("Content-Disposition", 'attachment; filename="%s.pdf"' % name)],
                               dual=DUAL_FRAMING)

    def handle_thumbnail(self, uid):
        if CATALOG.get(uid) is None:
            return self.send_json(500, {"error": "Unknown file"})
        return self.send_bytes(200, "image/jpeg", THUMB_PNG)

    def handle_log(self):
        try:
            with open(LOG_PATH, "rb") as f:
                data = f.read()
        except OSError:
            data = b""
        return self.send_bytes(200, "text/plain", data)


# ----------------------------------------------------------------------------- server
class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def local_ipv4s():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET, socket.SOCK_STREAM):
            ips.add(info[4][0])
    except socket.gaierror:
        pass
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, timeout=5).stdout
        ips.update(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)/", out))
    except Exception:  # noqa: BLE001
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def bind_all():
    """Bind the tablet address first; also bind the container's own interface so Docker's
    published port reaches us; fall back to the wildcard if nothing else works."""
    servers = []
    wanted = [PRIMARY_BIND] + [ip for ip in local_ipv4s() if ip != PRIMARY_BIND]
    for addr in wanted:
        try:
            servers.append(Server((addr, PORT), Handler))
            log("listening on %s:%d" % (addr, PORT))
        except OSError as e:
            log("cannot bind %s:%d: %s" % (addr, PORT, e))
    if not servers:
        servers.append(Server(("0.0.0.0", PORT), Handler))
        log("fallback: listening on 0.0.0.0:%d" % PORT)
    return servers


def web_interface_enabled():
    if IGNORE_CONF:
        return True
    try:
        with open(CONF_PATH, encoding="utf-8", errors="replace") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and k.strip() == "WebInterfaceEnabled":
                    return v.strip().lower() == "true"
    except OSError:
        log("no %s; assuming the web interface is enabled" % CONF_PATH)
        return True
    return False


def main():
    try:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (AttributeError, ValueError):
        pass
    try:
        with open(PID_PATH, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    log("mock web ui starting (pid %d; live-scan=%s strip-ext=%s upload-uses-last-folder=%s "
        "rmdoc-honors-parent=%s dual-framing=%s legacy-placeholder=%s)"
        % (os.getpid(), LIVE_SCAN, STRIP_EXT, USE_LAST_FOLDER, RMDOC_HONORS_PARENT, DUAL_FRAMING, LEGACY_PLACEHOLDER))
    if not web_interface_enabled():
        log("WebInterfaceEnabled is not true in %s: xochitl runs but opens no web socket" % CONF_PATH)
        while True:
            time.sleep(3600)
    CATALOG.scan()
    servers = bind_all()
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
