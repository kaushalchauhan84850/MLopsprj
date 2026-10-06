# -*- coding: utf-8 -*-
"""Render cover (template 01 HUD) and merge as page 1 of the guide."""
import os
import sys

PDF_SKILL = r"C:/Users/HP/.zcode/cli/plugins/cache/zcode-plugins-official/pdf/0.1.7/skills/pdf/scripts"
sys.path.insert(0, PDF_SKILL)

from cover_render import render_cover, detect_fonts
from pypdf import PdfReader, PdfWriter, Transformation

HERE = os.path.dirname(os.path.abspath(__file__))
COVER = os.path.join(HERE, "cover.pdf")
BODY = os.path.join(HERE, "K8s-AI-Ops-Interview-Guide.pdf")
FINAL = os.path.join(HERE, "K8s-AI-Ops-Interview-Guide-final.pdf")

CONTENT = {
    "kicker": "ML-POWERED KUBERNETES MONITORING",
    "hero": "K8s AI-Ops",
    "summary": ("From metric scrape to AI alert: how Prometheus, Grafana, Loki, KEDA and a custom "
                "MLOps layer connect, why every tool was chosen over its alternatives, and how each "
                "piece works internally - explained step by step for interview deep-dives."),
    "meta": "Architecture & Interview Guide  ·  October 2026  ·  k8s-ai-ops v1.0",
    "footer": "K8S-AI-OPS  ·  FROM SCRAPE TO ALERT",
    "year": "2026",
    "word": "GUIDE",
}
PALETTE = {"primary": "#32404e", "secondary": "#566574",
           "text": "#131415", "muted": "#74797e", "bg": "#ffffff"}

fonts = detect_fonts()
render_cover("01", CONTENT, COVER, palette=PALETTE, fonts=fonts)
print("cover rendered")

A4_W, A4_H = 595.28, 841.89


def normalize(page):
    box = page.mediabox
    w, h = float(box.width), float(box.height)
    if abs(w - A4_W) > 2 or abs(h - A4_H) > 2:
        page.add_transformation(Transformation().scale(sx=A4_W / w, sy=A4_H / h))
        page.mediabox.lower_left = (0, 0)
        page.mediabox.upper_right = (A4_W, A4_H)
    return page


writer = PdfWriter()
writer.add_page(normalize(PdfReader(COVER).pages[0]))
import pymupdf

_body = pymupdf.open(BODY)
for i, bp in enumerate(_body):
    _txt = bp.get_text().strip()
    if len(_txt) < 160 and len(bp.get_drawings()) < 3:
        print("skipping near-empty body page", i + 1)
        continue
    writer.add_page(normalize(PdfReader(BODY).pages[i]))
writer.add_metadata({
    "/Title": "ML-Powered Kubernetes Health Monitoring - Architecture & Interview Guide",
    "/Author": "Z.ai", "/Creator": "Z.ai",
    "/Subject": "End-to-end architecture, tooling rationale and interview Q&A for the k8s-ai-ops ML monitoring platform",
})
with open(FINAL, "wb") as f:
    writer.write(f)
print("MERGED:", FINAL, "pages:", len(writer.pages))
