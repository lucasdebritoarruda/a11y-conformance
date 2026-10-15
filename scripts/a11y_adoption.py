#!/usr/bin/env python3
"""
a11y_adoption.py — Adoção do design system e bypasses de acessibilidade em projetos iOS (UIKit).

Varre os módulos de feature (Swift, Objective-C, XIB e storyboard), compara o uso de
componentes e tokens do DS com o uso de UIKit "cru" e gera:

  <out>/adoption.md    relatório legível: tabelas por módulo, ranking de arquivos, achados
  <out>/adoption.json  dados completos, para CI e acompanhamento de tendência

Uso:
  python3 a11y_adoption.py --root . --config a11y_adoption.config.json --out a11y-report
  python3 a11y_adoption.py ... --ds-report a11y-report/ds        # inclui a auditoria do DS
  python3 a11y_adoption.py ... --fail-under-adoption 0.8         # quebra o CI abaixo do limite

Requer apenas Python 3.8+, sem dependências.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuração padrão (sobrescrita pelo arquivo passado em --config)
# ---------------------------------------------------------------------------

DEFAULT_CONFIG: dict = {
    # Pasta(s) cujas subpastas imediatas são módulos. Ignorado se "modules" for preenchido.
    "modules_root": "Modules",
    # Mapeamento explícito nome -> caminho, para estruturas irregulares.
    "modules": {},
    # Onde está o código do DS (usado para descobrir os componentes e para excluir da varredura).
    "design_system_paths": ["DesignSystem"],
    "exclude_globs": [
        "**/*Tests/**", "**/*Tests.swift", "**/*Tests.m",
        "**/Pods/**", "**/Carthage/**", "**/.build/**", "**/DerivedData/**", "**/SourcePackages/**",
    ],
    # Componentes interativos que não herdam de UIControl (ex.: UIView que contém um UISwitch).
    "ds_interactive_extra": [],
    "ds_interactive_exclude": [],
    # Se o DS tiver um label próprio que já nasce com Dynamic Type (ex.: "DSLabel"),
    # UILabel cru nos módulos passa a contar como bypass.
    "ds_label_class": None,
    "font_token_patterns": [r"\bDSTypography\.\w+", r"\bDSFont\.\w+"],
    "color_token_patterns": [r"\bDSColor\.\w+"],
    # Em XIB, cor com name="..." (Asset Catalog) conta como token?
    "xib_named_colors_are_tokens": True,
    # Chaves de cor verificadas em XIB. backgroundColor fica de fora por padrão (gera muito ruído).
    "xib_color_keys": [
        "textColor", "titleColor", "tintColor", "onTintColor", "thumbTintColor",
        "selectedSegmentTintColor", "highlightedColor", "placeholderColor",
    ],
    "allow_marker": "a11y-ok",
    "allowlist_file": "a11y-allowlist.txt",
    # Padrões extras por linguagem e categoria: {"swift": {"color_bypass": ["regex"]}, "objc": {...}}
    "extra_patterns": {"swift": {}, "objc": {}},
    # Regex (exatamente como escritas aqui) a desligar.
    "disabled_patterns": [],
}

UIKIT_INTERACTIVE_BASES = {
    "UIControl", "UIButton", "UISwitch", "UITextField", "UISlider",
    "UISegmentedControl", "UIStepper", "UIDatePicker", "UIPickerView",
}
XIB_INTERACTIVE_TAGS = {
    "button", "switch", "textField", "segmentedControl", "slider", "stepper", "datePicker", "pickerView",
}
XIB_TEXT_TAGS = {"label", "textField", "textView"}
CODE_EXTENSIONS = {".swift", ".m", ".mm"}
XIB_EXTENSIONS = {".xib", ".storyboard"}

BYPASS_CATEGORIES = ["interactive_native", "font_bypass", "color_bypass", "dynamic_type_off", "raw_label"]
COUNTER_CATEGORIES = ["ds_interactive", "font_token", "color_token", "label_created", "adjusts_true"]
CATEGORY_LABELS = {
    "interactive_native": "Interativo nativo",
    "font_bypass": "Fonte fora do token",
    "color_bypass": "Cor fora do token",
    "dynamic_type_off": "Sem Dynamic Type",
    "raw_label": "Label fora do DS",
}

_COLORS = "black|white|gray|lightGray|darkGray|red|green|blue|cyan|yellow|magenta|orange|purple|brown"

SWIFT_BYPASS = {
    "interactive_native": [
        r"\bUI(?:Button|Switch|TextField|SegmentedControl|Slider|Stepper|DatePicker|PickerView)\s*(?:\.init)?\s*\(",
        r"\bUIButton\.systemButton\s*\(",
        r"\bUITapGestureRecognizer\s*(?:\.init)?\s*\(",
        r"\bclass\s+\w+\s*:\s*UI(?:Control|Button|Switch|TextField|SegmentedControl|Slider|Stepper)\b",
    ],
    "font_bypass": [
        r"\bUIFont\.(?:systemFont|boldSystemFont|italicSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\s*\(\s*ofSize",
        r"\bUIFont\s*(?:\.init)?\s*\(\s*name\s*:",
        r"\.withSize\s*\(",
    ],
    "color_bypass": [
        r"\bUIColor\s*(?:\.init)?\s*\(\s*(?:red|white|hue|displayP3Red|hex\w*|rgb\w*)\s*:",
        rf"\bUIColor\.(?:{_COLORS})\b",
        rf"\b(?:textColor|tintColor|backgroundColor|borderColor|onTintColor|thumbTintColor)\s*=\s*\.(?:{_COLORS})\b",
        r"\bUIColor\s*(?:\.init)?\s*\(\s*named\s*:",
    ],
    "dynamic_type_off": [r"\badjustsFontForContentSizeCategory\s*=\s*false\b"],
}
SWIFT_COUNTERS = {
    "label_created": [r"\bUI(?:Label|TextField|TextView)\s*(?:\.init)?\s*\("],
    "adjusts_true": [r"\badjustsFontForContentSizeCategory\s*=\s*true\b"],
}
OBJC_BYPASS = {
    "interactive_native": [
        r"\[\s*UIButton\s+(?:buttonWithType|systemButtonWithImage)\s*:",
        r"\[\s*\[\s*UI(?:Button|Switch|TextField|SegmentedControl|Slider|Stepper|DatePicker|PickerView|TapGestureRecognizer)\s+alloc\s*\]",
        r"@interface\s+\w+\s*:\s*UI(?:Control|Button|Switch|TextField|SegmentedControl|Slider|Stepper)\b",
    ],
    "font_bypass": [
        r"\[\s*UIFont\s+(?:systemFontOfSize|boldSystemFontOfSize|italicSystemFontOfSize|fontWithName)\s*:",
        r"\bfontWithSize\s*:",
    ],
    "color_bypass": [
        r"\[\s*UIColor\s+colorWith(?:Red|White|Hue)\s*:",
        rf"\[\s*UIColor\s+(?:{_COLORS})Color\s*\]",
        r"\[\s*UIColor\s+colorNamed\s*:",
    ],
    "dynamic_type_off": [r"\badjustsFontForContentSizeCategory\s*=\s*NO\b"],
}
OBJC_COUNTERS = {
    "label_created": [r"\[\s*\[\s*UI(?:Label|TextField|TextView)\s+alloc\s*\]"],
    "adjusts_true": [r"\badjustsFontForContentSizeCategory\s*=\s*YES\b"],
}

SWIFT_CLASS_RE = re.compile(r"\b(?:(?:public|open|final)\s+)+class\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*([\w.]+)")
OBJC_IFACE_RE = re.compile(r"@interface\s+(\w+)\s*:\s*(\w+)")


# ---------------------------------------------------------------------------
# Estruturas
# ---------------------------------------------------------------------------

@dataclass
class Finding:
    module: str
    file: str
    location: str      # número da linha ou "#idDoObjetoNoXib"
    category: str
    snippet: str
    allowed: bool = False
    reason: str = ""


class Scan:
    def __init__(self, cfg: dict, allow_entries: set, ds_interactive: set, ds_all: set):
        self.cfg = cfg
        self.allow_entries = allow_entries
        self.ds_interactive = ds_interactive
        self.ds_all = ds_all
        self.stats: dict = defaultdict(Counter)
        self.findings: list = []
        self.warnings: list = []

    def add(self, module: str, rel: str, location: str, category: str, snippet: str, *,
            xib: bool, line: int | None = None, obj: str | None = None, inline_reason: str | None = None):
        allowed, reason = False, ""
        if inline_reason is not None:
            allowed, reason = True, inline_reason or self.cfg["allow_marker"]
        elif (rel in self.allow_entries
              or (line is not None and f"{rel}:{line}" in self.allow_entries)
              or (obj is not None and f"{rel}#{obj}" in self.allow_entries)):
            allowed, reason = True, "allowlist"
        self.findings.append(Finding(module, rel, location, category, snippet, allowed, reason))
        s = self.stats[module]
        if allowed:
            s["allowed"] += 1
        else:
            s[category] += 1
            s["bypass_xib" if xib else "bypass_code"] += 1


# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------

def load_config(path: Path | None) -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if path:
        user = json.loads(path.read_text(encoding="utf-8"))
        for key, value in user.items():
            if not key.startswith("_"):
                cfg[key] = value
    return cfg


def is_excluded(rel: str, globs: list) -> bool:
    p = rel.replace(os.sep, "/")
    return any(fnmatch.fnmatch(p, g) or fnmatch.fnmatch("/" + p, g) for g in globs)


def is_under(path: Path, parents: list) -> bool:
    for parent in parents:
        try:
            path.relative_to(parent)
            return True
        except ValueError:
            continue
    return False


def sanitize(source: str) -> list:
    """Apaga comentários e conteúdo de strings preservando colunas e linhas,
    para que padrões dentro de comentários/strings não sejam contados."""
    out = []
    i, n = 0, len(source)
    block_depth = 0
    in_string = False
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if block_depth:
            if c == "/" and nxt == "*":
                block_depth += 1; out.append("  "); i += 2; continue
            if c == "*" and nxt == "/":
                block_depth -= 1; out.append("  "); i += 2; continue
            out.append("\n" if c == "\n" else " "); i += 1; continue
        if in_string:
            if c == "\\":
                out.append(" \n" if nxt == "\n" else "  "); i += 2; continue
            if c == '"':
                in_string = False; out.append('"'); i += 1; continue
            if c == "\n":
                in_string = False; out.append("\n"); i += 1; continue
            out.append(" "); i += 1; continue
        if c == "/" and nxt == "/":
            end = source.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i)); i = end; continue
        if c == "/" and nxt == "*":
            block_depth = 1; out.append("  "); i += 2; continue
        if c == '"':
            in_string = True; out.append('"'); i += 1; continue
        out.append(c); i += 1
    return "".join(out).split("\n")


def load_allowlist(path: Path) -> set:
    entries = set()
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                entries.add(line.split()[0])
    return entries


def pct(value) -> str:
    return "–" if value is None else f"{value * 100:.0f}%"


def ratio(num: int, den: int):
    return None if den == 0 else num / den


def md(text) -> str:
    return str(text).replace("|", "\\|").replace("\n", " ").replace("`", "'")


# ---------------------------------------------------------------------------
# Descoberta do DS e dos módulos
# ---------------------------------------------------------------------------

def discover_ds(root: Path, cfg: dict):
    classes: dict = {}
    ds_paths = [(root / p) for p in cfg["design_system_paths"]]
    for base in ds_paths:
        if not base.exists():
            print(f"[aviso] caminho do DS não encontrado: {base}", file=sys.stderr)
            continue
        for path in base.rglob("*"):
            if path.suffix not in CODE_EXTENSIONS or not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            regex = SWIFT_CLASS_RE if path.suffix == ".swift" else OBJC_IFACE_RE
            for match in regex.finditer(text):
                classes.setdefault(match.group(1), match.group(2).split(".")[-1])

    interactive: set = set()
    changed = True
    while changed:
        changed = False
        for name, base in classes.items():
            if name not in interactive and (base in UIKIT_INTERACTIVE_BASES or base in interactive):
                interactive.add(name)
                changed = True

    interactive |= set(cfg["ds_interactive_extra"])
    interactive -= set(cfg["ds_interactive_exclude"])
    all_classes = set(classes) | interactive
    return interactive, all_classes, [p.resolve() for p in ds_paths if p.exists()]


def discover_modules(root: Path, cfg: dict) -> dict:
    if cfg["modules"]:
        return {name: (root / p).resolve() for name, p in cfg["modules"].items()}
    roots = cfg["modules_root"]
    roots = [roots] if isinstance(roots, str) else roots
    modules = {}
    for r in roots:
        base = root / r
        if not base.is_dir():
            print(f"[aviso] pasta de módulos não encontrada: {base}", file=sys.stderr)
            continue
        for d in sorted(base.iterdir()):
            if d.is_dir() and not d.name.startswith("."):
                modules[d.name] = d.resolve()
    return modules


# ---------------------------------------------------------------------------
# Padrões
# ---------------------------------------------------------------------------

def build_matchers(cfg: dict, ds_interactive: set) -> dict:
    disabled = set(cfg.get("disabled_patterns", []))
    swift_b = {k: list(v) for k, v in SWIFT_BYPASS.items()}
    swift_c = {k: list(v) for k, v in SWIFT_COUNTERS.items()}
    objc_b = {k: list(v) for k, v in OBJC_BYPASS.items()}
    objc_c = {k: list(v) for k, v in OBJC_COUNTERS.items()}

    if ds_interactive:
        names = "|".join(sorted((re.escape(n) for n in ds_interactive), key=len, reverse=True))
        swift_c["ds_interactive"] = [rf"\b(?:{names})\s*(?:\.init)?\s*\(", rf"\bclass\s+\w+\s*:\s*(?:{names})\b"]
        objc_c["ds_interactive"] = [rf"\[\s*\[\s*(?:{names})\s+alloc\s*\]", rf"@interface\s+\w+\s*:\s*(?:{names})\b"]

    label_class = cfg.get("ds_label_class")
    if label_class:
        esc = re.escape(label_class)
        swift_b["raw_label"] = [r"\bUILabel\s*(?:\.init)?\s*\("]
        objc_b["raw_label"] = [r"\[\s*\[\s*UILabel\s+alloc\s*\]"]
        for counters, pattern in ((swift_c, rf"\b{esc}\s*(?:\.init)?\s*\("), (objc_c, rf"\[\s*\[\s*{esc}\s+alloc\s*\]")):
            counters["label_created"] = counters["label_created"] + [pattern]
            counters["adjusts_true"] = counters["adjusts_true"] + [pattern]

    for counters in (swift_c, objc_c):
        counters["font_token"] = list(cfg["font_token_patterns"])
        counters["color_token"] = list(cfg["color_token_patterns"])

    extra = cfg.get("extra_patterns", {})
    for lang, bypass, counters in (("swift", swift_b, swift_c), ("objc", objc_b, objc_c)):
        for category, patterns in extra.get(lang, {}).items():
            target = bypass if category in BYPASS_CATEGORIES else counters
            target[category] = target.get(category, []) + list(patterns)

    def compile_all(groups: dict) -> dict:
        return {cat: [re.compile(p) for p in pats if p not in disabled] for cat, pats in groups.items()}

    return {
        "swift": {"bypass": compile_all(swift_b), "count": compile_all(swift_c)},
        "objc": {"bypass": compile_all(objc_b), "count": compile_all(objc_c)},
    }


# ---------------------------------------------------------------------------
# Varredura
# ---------------------------------------------------------------------------

def scan_code(path: Path, rel: str, module: str, matchers: dict, scan: Scan):
    text = path.read_text(encoding="utf-8", errors="replace")
    raw_lines = text.split("\n")
    clean_lines = sanitize(text)
    marker = scan.cfg["allow_marker"]
    marker_re = re.compile(re.escape(marker) + r"\s*:?\s*(.*)")
    lang = "swift" if path.suffix == ".swift" else "objc"
    stats = scan.stats[module]

    for index, line in enumerate(clean_lines):
        if not line.strip():
            continue
        raw = raw_lines[index] if index < len(raw_lines) else ""
        previous = raw_lines[index - 1].strip() if index > 0 else ""

        for category, regexes in matchers[lang]["bypass"].items():
            for regex in regexes:
                for _ in regex.finditer(line):
                    inline = None
                    hit = marker_re.search(raw) or (marker_re.search(previous) if previous.startswith("//") else None)
                    if hit:
                        inline = hit.group(1).strip()
                    scan.add(module, rel, str(index + 1), category, raw.strip()[:160],
                             xib=False, line=index + 1, inline_reason=inline)

        for category, regexes in matchers[lang]["count"].items():
            for regex in regexes:
                stats[category] += len(regex.findall(line))


def scan_xib(path: Path, rel: str, module: str, scan: Scan):
    try:
        tree = ET.parse(path)
    except ET.ParseError as error:
        scan.warnings.append(f"XML inválido em {rel}: {error}")
        return

    root = tree.getroot()
    parent_of = {child: parent for parent in root.iter() for child in parent}
    stats = scan.stats[module]
    cfg = scan.cfg

    def owner_id(element) -> str:
        current = element
        while current is not None:
            if current.get("id"):
                return current.get("id")
            current = parent_of.get(current)
        return "?"

    def describe(element) -> str:
        parts = [f"<{element.tag}"]
        for key in ("id", "customClass", "text", "title", "userLabel", "key"):
            if element.get(key):
                parts.append(f'{key}="{element.get(key)[:40]}"')
        return " ".join(parts) + ">"

    def report(element, category: str, snippet: str):
        oid = owner_id(element)
        scan.add(module, rel, f"#{oid}", category, snippet, xib=True, obj=oid)

    for element in root.iter():
        tag = element.tag
        custom_class = element.get("customClass")
        is_ds = bool(custom_class and custom_class in scan.ds_all)

        if tag in XIB_INTERACTIVE_TAGS:
            if is_ds:
                stats["ds_interactive"] += 1
            else:
                report(element, "interactive_native", describe(element))

        if tag in XIB_TEXT_TAGS:
            stats["label_created"] += 1
            adjusts = element.get("adjustsFontForContentSizeCategory") == "YES"
            if adjusts or is_ds:
                stats["adjusts_true"] += 1
            else:
                report(element, "dynamic_type_off", describe(element) + " sem adjustsFontForContentSizeCategory")
            font = element.find("fontDescription")
            if font is not None and not is_ds:
                if font.get("style"):
                    stats["font_token"] += 1  # text style do sistema: escala com Dynamic Type
                else:
                    attrs = " ".join(f'{k}="{v}"' for k, v in font.attrib.items() if k != "key")
                    report(element, "font_bypass", f"{describe(element)} fontDescription {attrs}")

        if tag == "color" and element.get("key") in cfg["xib_color_keys"]:
            if element.get("alpha") == "0":
                continue
            if element.get("name"):
                if cfg["xib_named_colors_are_tokens"]:
                    stats["color_token"] += 1
                else:
                    report(element, "color_bypass", f'<color key="{element.get("key")}" name="{element.get("name")}">')
            else:
                attrs = " ".join(f'{k}="{v}"' for k, v in element.attrib.items()
                                 if k in ("red", "green", "blue", "white", "systemColor", "cocoaTouchSystemColor"))
                report(element, "color_bypass", f'<color key="{element.get("key")}" {attrs}> em {owner_id(element)}')


def scan_repository(root: Path, cfg: dict):
    ds_interactive, ds_all, ds_paths = discover_ds(root, cfg)
    modules = discover_modules(root, cfg)
    allow_entries = load_allowlist(root / cfg["allowlist_file"]) if cfg.get("allowlist_file") else set()
    matchers = build_matchers(cfg, ds_interactive)
    scan = Scan(cfg, allow_entries, ds_interactive, ds_all)
    file_totals = Counter()

    for module, module_path in modules.items():
        if not module_path.is_dir():
            scan.warnings.append(f"módulo {module} não encontrado em {module_path}")
            continue
        if is_under(module_path, ds_paths):
            continue
        for path in sorted(module_path.rglob("*")):
            if not path.is_file() or path.suffix not in CODE_EXTENSIONS | XIB_EXTENSIONS:
                continue
            rel = path.resolve().relative_to(root.resolve()).as_posix()
            if is_excluded(rel, cfg["exclude_globs"]) or is_under(path.resolve(), ds_paths):
                continue
            scan.stats[module]["files"] += 1
            if path.suffix in XIB_EXTENSIONS:
                file_totals["xib"] += 1
                scan_xib(path, rel, module, scan)
            else:
                file_totals["code"] += 1
                scan_code(path, rel, module, matchers, scan)

    return scan, modules, file_totals


# ---------------------------------------------------------------------------
# Métricas e relatórios
# ---------------------------------------------------------------------------

def compute_metrics(c: Counter) -> dict:
    return {
        "adoption_interactive": ratio(c["ds_interactive"], c["ds_interactive"] + c["interactive_native"]),
        "font_adherence": ratio(c["font_token"], c["font_token"] + c["font_bypass"]),
        "color_adherence": ratio(c["color_token"], c["color_token"] + c["color_bypass"]),
        "dynamic_type_coverage": None if c["label_created"] == 0 else min(1.0, c["adjusts_true"] / c["label_created"]),
        "bypasses_code": c["bypass_code"],
        "bypasses_xib": c["bypass_xib"],
        "allowed": c["allowed"],
        "files": c["files"],
    }


def load_ds_report(directory: Path) -> list:
    suites = []
    if not directory.is_dir():
        print(f"[aviso] pasta do relatório do DS não encontrada: {directory}", file=sys.stderr)
        return suites
    for f in sorted(directory.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"[aviso] ignorando {f}: {error}", file=sys.stderr)
            continue
        if isinstance(data, dict) and isinstance(data.get("results"), list):
            suites.append(data)
    return suites


def summarize_ds_suite(suite: dict) -> dict:
    results = suite["results"]
    subjects = list(dict.fromkeys(r["subject"] for r in results))
    passing = [s for s in subjects if all(r["passed"] for r in results if r["subject"] == s)]
    return {"suite": suite["suite"], "conformant": len(passing), "total": len(subjects),
            "rate": ratio(len(passing), len(subjects))}


def render_ds_section(suites: list) -> list:
    lines = ["## Auditoria do design system", ""]
    if not suites:
        return lines + ["Nenhum relatório encontrado.", ""]
    for suite in suites:
        results = suite["results"]
        subjects = list(dict.fromkeys(r["subject"] for r in results))
        criteria = list(dict.fromkeys(r["criterion"] for r in results))
        cells = {(r["subject"], r["criterion"]): r for r in results}
        summary = summarize_ds_suite(suite)
        lines += [
            f"### {suite['suite']}",
            "",
            f"**{summary['conformant']} de {summary['total']} ({pct(summary['rate'])}) totalmente conformes** "
            f"· gerado em {suite.get('generatedAt', '?')}",
            "",
            "| Item | " + " | ".join(md(c) for c in criteria) + " |",
            "|---|" + "---|" * len(criteria),
        ]
        for subject in subjects:
            row = []
            for criterion in criteria:
                r = cells.get((subject, criterion))
                row.append("–" if r is None else ("✅" if r["passed"] else "❌"))
            lines.append(f"| {md(subject)} | " + " | ".join(row) + " |")
        failures = [r for r in results if not r["passed"]]
        if failures:
            lines += ["", "<details><summary>Falhas</summary>", ""]
            lines += [f"- **{md(r['subject'])}** › {md(r['criterion'])}: {md(r['detail'])}" for r in failures]
            lines += ["", "</details>"]
        lines.append("")
    return lines


def render_markdown(root: Path, scan: Scan, modules: dict, file_totals: Counter,
                    per_module: dict, total: dict, ds_suites: list | None, detail_limit: int) -> str:
    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
    lines = [
        "# Adoção do design system e bypasses de acessibilidade",
        "",
        f"Gerado em {now} · {file_totals['code']} arquivos de código e "
        f"{file_totals['xib']} XIB/storyboard em {len(modules)} módulo(s).",
        "",
    ]

    if ds_suites is not None:
        lines += render_ds_section(ds_suites)

    interactive = sorted(scan.ds_interactive)
    others = sorted(scan.ds_all - scan.ds_interactive)
    lines += [
        "## Componentes do DS detectados",
        "",
        f"**Interativos ({len(interactive)}):** " + (", ".join(f"`{n}`" for n in interactive) or "nenhum"),
        "",
        f"**Outros ({len(others)}):** " + (", ".join(f"`{n}`" for n in others) or "nenhum"),
        "",
        "Se algum componente interativo não aparece na primeira lista (ex.: uma UIView que contém um UISwitch), "
        "inclua-o em `ds_interactive_extra` na configuração.",
        "",
        "## Resumo por módulo",
        "",
        "| Módulo | Adoção interativos | Aderência fonte | Aderência cor | Dynamic Type (est.) "
        "| Bypasses código | Bypasses XIB | Permitidos |",
        "|---|---|---|---|---|---|---|---|",
    ]

    def row(name, m):
        return (f"| {name} | {pct(m['adoption_interactive'])} | {pct(m['font_adherence'])} | "
                f"{pct(m['color_adherence'])} | {pct(m['dynamic_type_coverage'])} | "
                f"{m['bypasses_code']} | {m['bypasses_xib']} | {m['allowed']} |")

    for name in modules:
        lines.append(row(md(name), per_module[name]["metrics"]))
    lines.append(row("**Total**", total["metrics"]))

    lines += [
        "",
        "Dynamic Type em código é uma estimativa (labels criados × `adjustsFontForContentSizeCategory = true`); "
        "em XIB/storyboard é exato.",
        "",
        "## Bypasses por categoria",
        "",
        "| Módulo | " + " | ".join(CATEGORY_LABELS[c] for c in BYPASS_CATEGORIES) + " |",
        "|---|" + "---|" * len(BYPASS_CATEGORIES),
    ]
    for name in modules:
        counts = per_module[name]["counts"]
        lines.append(f"| {md(name)} | " + " | ".join(str(counts.get(c, 0)) for c in BYPASS_CATEGORIES) + " |")

    ranking = Counter()
    categories_by_file: dict = defaultdict(set)
    for f in scan.findings:
        if not f.allowed:
            ranking[(f.module, f.file)] += 1
            categories_by_file[f.file].add(CATEGORY_LABELS[f.category])
    lines += [
        "",
        "## Arquivos com mais bypasses",
        "",
        "Lista de trabalho para a revisão por IA e o teste manual.",
        "",
        "| Arquivo | Módulo | Bypasses | Categorias |",
        "|---|---|---|---|",
    ]
    for (module, file), count in ranking.most_common(20):
        lines.append(f"| `{md(file)}` | {md(module)} | {count} | {', '.join(sorted(categories_by_file[file]))} |")
    if not ranking:
        lines.append("| – | – | 0 | – |")

    lines += ["", "## Achados por módulo", ""]
    for name in modules:
        module_findings = [f for f in scan.findings if f.module == name and not f.allowed]
        if not module_findings:
            continue
        lines += [f"### {md(name)} ({len(module_findings)})", ""]
        for f in module_findings[:detail_limit]:
            sep = ":" if not f.location.startswith("#") else ""
            lines.append(f"- `{md(f.file)}{sep}{md(f.location)}` · {CATEGORY_LABELS[f.category]} · `{md(f.snippet)}`")
        if len(module_findings) > detail_limit:
            lines.append(f"- … mais {len(module_findings) - detail_limit} (lista completa em adoption.json)")
        lines.append("")

    allowed = [f for f in scan.findings if f.allowed]
    if allowed:
        lines += ["## Permitidos (a11y-ok / allowlist)", "", "Revise periodicamente: cada exceção é uma dívida consciente.", ""]
        for f in allowed:
            sep = ":" if not f.location.startswith("#") else ""
            lines.append(f"- `{md(f.file)}{sep}{md(f.location)}` · {CATEGORY_LABELS[f.category]} · {md(f.reason)}")
        lines.append("")

    if scan.warnings:
        lines += ["## Avisos", ""] + [f"- {md(w)}" for w in scan.warnings] + [""]

    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Adoção do DS e bypasses de acessibilidade (UIKit).")
    parser.add_argument("--root", default=".", help="raiz do repositório")
    parser.add_argument("--config", help="arquivo JSON de configuração")
    parser.add_argument("--out", default="a11y-report", help="pasta de saída")
    parser.add_argument("--ds-report", help="pasta com os JSON gerados pelos testes do DS (A11Y_REPORT_DIR)")
    parser.add_argument("--detail-limit", type=int, default=200, help="máximo de achados listados por módulo no .md")
    parser.add_argument("--fail-under-adoption", type=float, help="falha se a adoção total de interativos ficar abaixo (0–1)")
    parser.add_argument("--fail-under-font", type=float, help="falha se a aderência total de fonte ficar abaixo (0–1)")
    parser.add_argument("--fail-under-color", type=float, help="falha se a aderência total de cor ficar abaixo (0–1)")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    cfg = load_config(Path(args.config) if args.config else None)
    scan, modules, file_totals = scan_repository(root, cfg)

    per_module = {}
    total_counts = Counter()
    for name in modules:
        counts = scan.stats[name]
        total_counts.update(counts)
        per_module[name] = {"counts": dict(counts), "metrics": compute_metrics(counts)}
    total = {"counts": dict(total_counts), "metrics": compute_metrics(total_counts)}

    ds_suites = load_ds_report(Path(args.ds_report)) if args.ds_report else None

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "adoption.md").write_text(
        render_markdown(root, scan, modules, file_totals, per_module, total, ds_suites, args.detail_limit),
        encoding="utf-8")
    (out / "adoption.json").write_text(json.dumps({
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "designSystem": {"interactive": sorted(scan.ds_interactive),
                         "other": sorted(scan.ds_all - scan.ds_interactive)},
        "modules": per_module,
        "total": total,
        "dsAudit": [summarize_ds_suite(s) for s in ds_suites] if ds_suites is not None else None,
        "findings": [asdict(f) for f in scan.findings],
        "warnings": scan.warnings,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    m = total["metrics"]
    print(f"Módulos: {len(modules)} · arquivos: {file_totals['code']} código, {file_totals['xib']} XIB/storyboard")
    print(f"Adoção interativos: {pct(m['adoption_interactive'])} · fonte: {pct(m['font_adherence'])} · "
          f"cor: {pct(m['color_adherence'])} · Dynamic Type (est.): {pct(m['dynamic_type_coverage'])}")
    print(f"Bypasses: {m['bypasses_code']} em código, {m['bypasses_xib']} em XIB · permitidos: {m['allowed']}")
    print(f"Relatório: {out / 'adoption.md'}")

    failures = []
    for flag, key, label in ((args.fail_under_adoption, "adoption_interactive", "adoção de interativos"),
                             (args.fail_under_font, "font_adherence", "aderência de fonte"),
                             (args.fail_under_color, "color_adherence", "aderência de cor")):
        if flag is not None and m[key] is not None and m[key] < flag:
            failures.append(f"{label} {pct(m[key])} abaixo do mínimo {pct(flag)}")
    for failure in failures:
        print(f"[falha] {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
