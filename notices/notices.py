"""Writes each application's THIRD-PARTY-NOTICES.txt: the third-party software built into its exe, with the licence
texts that software asks to travel with it.

    python notices/notices.py           write THIRD-PARTY-NOTICES.txt into each application's checkout
    python notices/notices.py --check   also look for each component in the built exes (exe/, from deploy.ps1, or
                                        <app>/target), and fail when one is missing or an unlisted one is present

Each application's installer.json installs the file next to its exe, so a release must be generated after this has
run. Run it again whenever a dependency changes: a new library, a new version, a new GraalVM. --check compares the
list below against what the exes actually contain, which is how the list was made.

The Rust crates in Pix and Vexplore (imagelib-wrapper's native library) are read from cargo: `cargo tree` gives the
crates built into the library for Windows (no dev, build or proc-macro crates), `cargo metadata` where each one's
source is, and each crate's own licence files are copied from that source. Needs cargo and the crates fetched, as
building imagelib-wrapper does. The licence texts of everything else are in licenses/, copied from the component or,
for GraalVM, from the GraalVM distribution the exes were built with.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.dirname(HERE)
ROOT = os.path.dirname(DIST)
LIC = os.path.join(HERE, "licenses")
IMAGELIB = os.path.join(ROOT, "imagelib-wrapper", "native", "imagelib")
TARGET = "x86_64-pc-windows-msvc"
NAME = "THIRD-PARTY-NOTICES.txt"
RULE = "=" * 79
THIN = "-" * 79


def text(name):
    with open(os.path.join(LIC, name), encoding="utf-8") as h:
        return h.read().replace("\r\n", "\n").strip("\n")


def markdown(name):
    """The JDK's and EPL's notices are Markdown with HTML <pre> blocks; as plain text, without the markup."""
    t = text(name)
    t = re.sub(r"</?pre>", "", t)
    t = re.sub(r"^#+ *", "", t, flags=re.M)
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = t.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\n{3,}", "\n\n", t).strip("\n")


# The licence texts shared by several components, each printed once at the end of the file.
LICENSES = {
    "Apache-2.0": ("Apache License 2.0", lambda: text("Apache-2.0.txt")),
    "MIT": ("MIT License", lambda: text("MIT.txt")),
    "UPL-1.0": ("Universal Permissive License 1.0", lambda: text("UPL-1.0.txt")),
    "OFL-1.1": ("SIL Open Font License 1.1", lambda: text("OFL-1.1.txt")),
    "Zlib": ("zlib License", lambda: text("Zlib.txt")),
    "EPL-2.0": ("Eclipse Public License 2.0", lambda: markdown("EPL-2.0.md")),
    "GFTC": ("GraalVM Free Terms and Conditions (GFTC)", lambda: text("GFTC.txt")),
    "NFTC": ("Oracle No-Fee Terms and Conditions (NFTC)", lambda: text("NFTC.txt")),
}


class Component:
    def __init__(self, title, version, url, licenses, notices, markers, note="", appendix=(), new=False):
        self.title, self.version, self.url = title, version, url
        self.new = new                  # added since the last release: an older exe may lack it
        self.licenses = licenses        # keys of LICENSES whose full text this component needs
        self.notices = notices          # copyright lines, as the component states them
        self.markers = markers          # strings that are in an exe exactly when this component is
        self.note, self.appendix = note, appendix   # appendix: (title, text loader) printed after the licences


C = {
    "graalvm": Component(
        "Oracle GraalVM Native Image runtime and Java class library", "25.0.3", "https://www.graalvm.org/",
        ["GFTC", "NFTC"],
        ["Copyright (c) 1993, 2026, Oracle and/or its affiliates. All rights reserved."],
        ["GraalVM 25.0.3"],
        "The program is compiled ahead of time with Oracle GraalVM Native Image, which builds its runtime (garbage "
        "collector, threads, exceptions) and the parts of the Java class library it uses into the executable. "
        "Oracle GraalVM is used under the GraalVM Free Terms and Conditions; the Java class library is licensed "
        "under the Oracle No-Fee Terms and Conditions (see the distribution's legal/java.base/LICENSE). Both texts "
        "follow, and so do the notices for the third-party code in that class library.",
        [("zlib 1.3.1, in the Java class library", lambda: markdown("jdk/java.base-zlib.md")),
         ("ICU, in the Java class library", lambda: markdown("jdk/java.base-icu.md")),
         ("Unicode Character Database, in the Java class library", lambda: markdown("jdk/java.base-unicode.md")),
         ("Unicode Common Locale Data Repository (CLDR), in the Java class library", lambda: markdown("jdk/java.base-cldr.md")),
         ("Cryptix AES, in the Java class library", lambda: markdown("jdk/java.base-aes.md"))]),
    "jdk-xml": Component(
        "Apache Xerces and the W3C DOM, in the Java class library (java.xml)", "", "https://openjdk.org/",
        [], [], ["com.sun.org.apache.xerces.internal.dom.AttrNS"],
        "Vex reads and checks XML with the Java class library's XML parser, which is based on Apache Xerces. "
        "Oracle's notices for it follow.",
        [("Apache Xerces, in the Java class library", lambda: markdown("jdk/java.xml-xerces.md")),
         ("W3C DOM, in the Java class library", lambda: markdown("jdk/java.xml-dom.md"))]),
    "truffle": Component(
        "Truffle and the GraalVM SDK (truffle-api, polyglot, collections, nativeimage, word)", "25.0.1",
        "https://github.com/oracle/graal",
        ["UPL-1.0"], ["Copyright (c) Oracle and/or its affiliates. All rights reserved."],
        ["com.oracle.truffle.api"]),
    "noto": Component(
        "Noto Sans and Noto Sans Mono fonts", "2.015 and 2.014", "https://github.com/notofonts/latin-greek-cyrillic",
        ["OFL-1.1"],
        ["Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic)"],
        ["NotoSans"],
        "The fonts' glyphs are built into the program as signed-distance-field atlases, which it draws its text "
        "from. The fonts themselves are not included."),
    "noto-styles": Component(
        "Noto Sans Bold, Italic and Bold Italic fonts", "2.015", "https://github.com/notofonts/latin-greek-cyrillic",
        ["OFL-1.1"],
        ["Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic)"],
        ["NotoSans-Italic.ttf"],
        "Built into the program as signed-distance-field atlases, like Noto Sans above.", new=True),
    "nfd": Component(
        "nativefiledialog-extended (nfd.dll)", "", "https://github.com/btzy/nativefiledialog-extended",
        ["Zlib"],
        ["nativefiledialog-extended, by Bernard Teo and contributors, based on nativefiledialog by Michael Labbe."],
        ["nfd.dll"],
        "Shows Windows' own open and save dialogs. The DLL is stored in the program and written out next to it, "
        "or to a temporary folder, when a dialog is first opened."),
    "spirv-grammar": Component(
        "SPIR-V grammar (Khronos SPIRV-Headers, spirv.core.grammar.json, SPIR-V 1.6 revision 4)", "",
        "https://github.com/KhronosGroup/SPIRV-Headers",
        ["MIT"], ["Copyright 2014-2024 The Khronos Group Inc."],
        ["OpLoad"],
        "The program's shader compiler is generated from this grammar, and the generated code is built in."),
    "spirv-tools": Component(
        "SPIRV-Tools (spirv-as, spirv-dis, spirv-opt, spirv-val)", "v2026.2, from the LunarG Vulkan SDK 1.4.350.0",
        "https://github.com/KhronosGroup/SPIRV-Tools",
        ["Apache-2.0"],
        ["Copyright (c) The Khronos Group Inc., Google LLC, and the other SPIRV-Tools authors."],
        ["spirv-opt"],
        "The executables are stored in the program and run as separate processes, to validate and optimise the "
        "shaders it generates. They include SPIRV-Headers (MIT, see above)."),
    "spirv-cross": Component(
        "SPIRV-Cross (spirv-cross)", "from the LunarG Vulkan SDK 1.4.350.0", "https://github.com/KhronosGroup/SPIRV-Cross",
        ["Apache-2.0"], ["Copyright 2015-2021 Arm Limited, and the other SPIRV-Cross authors."],
        ["spirv-cross"],
        "Stored in the program and run as a separate process, like SPIRV-Tools."),
    "tm4e": Component(
        "Eclipse TM4E core", "0.14.0 (as packaged by Apache NetBeans, RELEASE260)", "https://github.com/eclipse-tm4e/tm4e",
        ["EPL-2.0"], ["Copyright (c) 2015, 2024 Angelo ZERR and other Eclipse TM4E contributors."],
        ["org.eclipse.tm4e"],
        "TM4E is distributed here in object code under the Eclipse Public License 2.0. Its source code is "
        "available from https://github.com/eclipse-tm4e/tm4e (tag 0.14.0)."),
    "vscode-grammars": Component(
        "TextMate grammars from Visual Studio Code", "", "https://github.com/microsoft/vscode",
        ["MIT"], ["Copyright (c) 2015 - present Microsoft Corporation"],
        ["This file has been converted from"],
        "The grammars Vex highlights with are taken from Visual Studio Code, which converted them from these "
        "projects: microsoft/vscode-JSON.tmLanguage, microsoft/TypeScript-TmLanguage, mmims/language-batchfile, "
        "microsoft/vscode-css, textmate/diff.tmbundle, moby/moby (Dockerfile), textmate/html.tmbundle, "
        "textmate/ini.tmbundle, redhat-developer/vscode-java, microsoft/vscode-markdown-tm-grammar, "
        "PowerShell/EditorSyntax, MagicStack/MagicPython, jeff-hykin/better-shell-syntax, atom/language-xml and "
        "textmate/yaml.tmbundle (each on GitHub). Visual Studio Code's ThirdPartyNotices.txt gives their notices."),
    "joni": Component(
        "Joni (Java port of the Oniguruma regular expression library)", "2.2.1", "https://github.com/jruby/joni",
        ["MIT"], ["Joni, by the JRuby team, distributed under the MIT License."], ["org.joni"]),
    "jcodings": Component(
        "JCodings", "1.0.58", "https://github.com/jruby/jcodings",
        ["MIT"], ["JCodings, by the JRuby team, distributed under the MIT License."], ["org.jcodings.specific"]),
    "gson": Component(
        "Gson", "2.11.0", "https://github.com/google/gson",
        ["Apache-2.0"], ["Copyright (C) 2008 Google Inc."], ["com.google.gson"]),
    "snakeyaml": Component(
        "SnakeYAML Engine", "2.7", "https://bitbucket.org/snakeyaml/snakeyaml-engine",
        ["Apache-2.0"], ["Copyright (c) 2018, SnakeYAML", "Copyright (c) 2008 Google Inc."], ["org.snakeyaml.engine"]),
    "javaparser": Component(
        "JavaParser (javaparser-core)", "3.28.2", "https://github.com/javaparser/javaparser",
        ["Apache-2.0"],
        ["Copyright (C) 2007-2010 Júlio Vilmar Gesser.", "Copyright (C) 2011, 2013-2026 The JavaParser Team."],
        ["com.github.javaparser"],
        "JavaParser is dual-licensed under the GNU Lesser General Public License 3.0 or later and the Apache "
        "License 2.0. It is used here under the Apache License 2.0."),
    "vineflower": Component(
        "Vineflower (Java decompiler, based on JetBrains Fernflower)", "1.12.0", "https://github.com/Vineflower/vineflower",
        ["Apache-2.0"], ["Copyright 2000-2023 JetBrains s.r.o.", "Copyright the Vineflower contributors."],
        ["org.jetbrains.java.decompiler"]),
}

EVERY_APP = ["graalvm", "truffle", "noto", "nfd", "spirv-grammar"]
SIMS = EVERY_APP + ["spirv-tools", "spirv-cross"]

# id: (checkout holding installer.json, components, has imagelib, a note for files installed beside the exe)
APPS = {
    "vexplore": ("vexplore", EVERY_APP, True, ""),
    "text-editor": ("text-editor-vexel-demo",
                    EVERY_APP + ["noto-styles", "jdk-xml", "tm4e", "vscode-grammars", "joni", "jcodings", "gson",
                                 "snakeyaml", "javaparser", "vineflower"], False, ""),
    "pix": ("Pix", EVERY_APP, True,
            "The ffmpeg folder next to Pix holds FFmpeg's libraries, which Pix uses to show a frame of a video. "
            "They are not part of pix.exe. FFmpeg is licensed under the GNU Lesser General Public License; its "
            "licence and where to get its source are in ffmpeg\\FFMPEG-LICENSE.txt and ffmpeg\\FFMPEG-SOURCE.txt."),
    "mainframe": ("mainframe", EVERY_APP, False, ""),
    "calculator": ("calculator-vexel-demo", EVERY_APP, False, ""),
    "fluid-sim": ("vexelray-sim-fluid", SIMS, False, ""),
    "rigid-sim": ("vexelray-sim-rigid", SIMS, False, ""),
}

# Markers of what the exes must not contain unless listed: a dependency that is declared but not compiled in.
NOT_LISTED = {"org.joml": "JOML"}


def cargo(*args):
    return subprocess.run(["cargo", *args], cwd=IMAGELIB, capture_output=True, text=True, encoding="utf-8",
                          check=True).stdout


# preferred licence when a crate offers a choice: the ones that ask least, and whose files carry the copyright
PREFERENCE = ["MIT", "Zlib", "BSD-3-Clause", "BSD-2-Clause", "0BSD", "Unlicense", "Apache-2.0"]
FILES = {"MIT": ["LICENSE-MIT", "LICENSE-MIT.md", "LICENSE-MIT.txt"], "Zlib": ["LICENSE-ZLIB", "LICENSE-ZLIB.md"],
         "BSD-3-Clause": ["LICENSE-BSD", "LICENSE.md"], "BSD-2-Clause": ["LICENSE-BSD"],
         "Apache-2.0": ["LICENSE-APACHE", "LICENSE-APACHE.md"]}


def crates():
    """The crates linked into imagelib for Windows, each with the licence chosen and that licence's text."""
    tree = cargo("tree", "--offline", "-e", "normal,no-proc-macro", "--target", TARGET, "--prefix", "none",
                 "--format", "{p}")
    wanted = {re.sub(r" \(.*$", "", line.strip()) for line in tree.splitlines() if line.strip()}
    meta = json.loads(cargo("metadata", "--offline", "--format-version", "1", "--filter-platform", TARGET))
    found = {}
    for p in meta["packages"]:
        key = f"{p['name']} v{p['version']}"
        if key in wanted and p["source"] is not None:
            found[key] = p
    out = []
    for key in sorted(found, key=lambda k: (found[k]["name"], k)):
        p = found[key]
        d = os.path.dirname(p["manifest_path"])
        offered = re.split(r"\s+OR\s+|/", re.sub(r"[()]", "", p["license"] or ""))
        chosen = next((l for l in PREFERENCE if l in offered), offered[0])
        files = [f for f in os.listdir(d) if f.upper().startswith(("LICEN", "COPYING", "COPYRIGHT", "NOTICE"))]
        pick = next((f for f in FILES.get(chosen, []) if f in files), None)
        if pick is None and len([f for f in files if f.upper().startswith("LICEN")]) == 1:
            pick = next(f for f in files if f.upper().startswith("LICEN"))
        if pick is None:
            # zune-core and zune-jpeg 0.4 ship without licence files; their newer versions, same authors and
            # licence, have them
            sib = [q for q in meta["packages"] if q["name"] == p["name"] and q is not p and q["source"]]
            for q in sib:
                qd = os.path.dirname(q["manifest_path"])
                pick = next((os.path.join(qd, f) for f in FILES.get(chosen, []) if os.path.exists(os.path.join(qd, f))), None)
                if pick:
                    break
        if pick is None and chosen == "MIT" and "COPYING" in files:
            # siphasher ships only COPYING, which names the licences and the copyright: the MIT text under it
            body = text("MIT.txt")
        elif pick is None:
            sys.exit(f"{key}: no licence file for {chosen} in {d}")
        else:
            with open(os.path.join(d, pick), encoding="utf-8") as h:
                body = h.read().replace("\r\n", "\n").strip("\n")
        stated = re.search(r"(?im)^\W*(copyright.*(\(c\)|©|\d{4})|\(c\)|©)", body)
        if (chosen != "Apache-2.0" and not stated and "COPYING" not in files and "COPYRIGHT" not in files
                and p.get("authors")):
            body = "Copyright (c) " + ", ".join(re.sub(r" <.*?>", "", a) for a in p["authors"]) + "\n\n" + body
        for extra in ("COPYING", "COPYRIGHT", "NOTICE"):
            if extra in files:
                with open(os.path.join(d, extra), encoding="utf-8") as h:
                    body = h.read().replace("\r\n", "\n").strip("\n") + "\n\n" + body
        out.append((p["name"], p["version"], p["license"], chosen, body))
    return out


def rust_section(crate_list):
    lines = ["imagelib, the image decoding library built into this program, is written in Rust. It contains the "
             "Rust standard library and the crates listed here, each under the licence it offers that is named, "
             "followed by that crate's own licence file. Crates with identical licence files share one copy.", ""]
    lines.append("Rust standard library: Copyright The Rust Project Developers (see https://thanks.rust-lang.org). "
                 "Used under the MIT License (it is offered under MIT or Apache-2.0); the MIT License text is in "
                 "the licence texts at the end of this file. Its Unicode tables are Copyright 1991-2024 Unicode, "
                 "Inc., under the Unicode License v3. Every Rust distribution lists the crates the standard "
                 "library is built from, with their notices, in share/doc/rust/COPYRIGHT-library.html.")
    lines.append("")
    groups = {}
    for name, version, offered, chosen, body in crate_list:
        groups.setdefault(body, []).append(f"{name} {version} ({offered}; used under {chosen})")
    for body, users in groups.items():
        lines.append(THIN)
        lines += users
        lines.append("")
        lines.append(body)
        lines.append("")
    return lines


def render(name, components, rust, beside):
    out = [f"{name}: third-party software notices", "",
           f"{name} contains the third-party software listed below. Each item names its licence; the full texts of "
           "the licences are at the end of this file. The rest of the program is VexelRay's own code.", ""]
    if beside:
        out += [beside, ""]
    needed = []
    for n, key in enumerate(components, 1):
        c = C[key]
        out += [RULE, f"{n}. {c.title}" + (f" {c.version}" if c.version else ""), c.url]
        if c.licenses:
            out.append("Licence: " + ", ".join(LICENSES[l][0] for l in c.licenses))
        out += c.notices
        if c.note:
            out += ["", c.note]
        out.append("")
        for l in c.licenses:
            if l not in needed:
                needed.append(l)
    if rust:
        out += [RULE, f"{len(components) + 1}. Rust crates in imagelib ({len(rust)} crates)",
                "https://github.com/image-rs/image, https://github.com/linebender/resvg", ""]
        out += rust_section(rust)
        if "MIT" not in needed:
            needed.append("MIT")
    out += [RULE, "Licence texts", RULE, ""]
    for l in needed:
        title, body = LICENSES[l]
        out += [THIN, title, THIN, "", body(), ""]
    if rust:
        out += [THIN, "Unicode License v3", THIN, "", text("Unicode-3.0.txt"), ""]
    for key in components:
        for title, body in C[key].appendix:
            out += [THIN, title, THIN, "", body(), ""]
    return "\r\n".join(out).rstrip("\r\n") + "\r\n"


def exe_of(app_id, folder, config):
    """The exe a release would ship (the build in the checkout), else the last one deploy.ps1 generated from."""
    built = os.path.join(folder, config["windows"]["binaries"][0]["source"])
    for p in (built, os.path.join(DIST, "exe", app_id + ".exe")):
        if os.path.exists(p):
            return p
    return None


def check(app_id, exe, components, rust):
    with open(exe, "rb") as h:
        data = h.read()
    problems = []
    for key, c in C.items():
        present = all(m.encode() in data for m in c.markers)
        if key in components and not present and c.new:
            print(f"[{app_id}] {exe} predates {c.title}; a new build will carry it")
        elif key in components and not present:
            problems.append(f"lists {c.title}, but {exe} has no {c.markers}")
        if key not in components and present:
            problems.append(f"{exe} contains {c.title} ({c.markers}), which is not listed")
    has_rust = b"resvg" in data
    if bool(rust) != has_rust:
        problems.append(f"imagelib (Rust) {'missing from' if rust else 'unlisted in'} {exe}")
    for marker, what in NOT_LISTED.items():
        if marker.encode() in data:
            problems.append(f"{exe} contains {what} ({marker}), which is not listed")
    return problems


def main():
    checking = "--check" in sys.argv[1:]
    crate_list = crates()
    failed = False
    for app_id, (checkout, components, has_rust, beside) in APPS.items():
        folder = os.path.join(ROOT, checkout)
        with open(os.path.join(folder, "installer.json"), encoding="utf-8") as h:
            config = json.load(h)
        name = config["name"]
        rust = crate_list if has_rust else None
        body = render(name, components, rust, beside)
        with open(os.path.join(folder, NAME), "w", encoding="utf-8", newline="") as h:
            h.write(body)
        print(f"[{app_id}] {checkout}/{NAME}: {len(components) + (1 if rust else 0)} items, {len(body) // 1024} KB")
        if checking:
            exe = exe_of(app_id, folder, config)
            if not exe:
                print(f"[{app_id}] no exe to check (exe/{app_id}.exe)")
                failed = True
                continue
            for p in check(app_id, exe, components, rust):
                print(f"[{app_id}] {p}")
                failed = True
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
