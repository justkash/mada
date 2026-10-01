# Renders Mermaid diagrams to the terminal; used by mada to render Mermaid blocks.
{ lib, python3Packages, fetchPypi }:

python3Packages.buildPythonApplication rec {
  pname = "termaid";
  version = "0.9.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-Cxg/E5Y4AVsKjVK+IUBQGH6h6UTCxvhrQExnXJ48etY=";
  };

  # Upstream's CLI accepts --width but does not pass it to the Gantt renderer.
  patches = [ ./termaid-gantt-width.patch ];

  build-system = [ python3Packages.hatchling ];

  # Tests need pytest-snapshot and other dev deps that aren't packaged here.
  doCheck = false;
  pythonImportsCheck = [ "termaid" ];

  # The Python builder skips installCheckPhase; verify the wrapped CLI here.
  postFixup = ''
    python - "$out/bin/termaid" <<'PY'
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(next((Path(sys.argv[1]).parent.parent / "lib").glob("python*/site-packages"))))
from termaid.utils import display_width

cli = sys.argv[1]
gantt = """gantt
    title Roadmap
    dateFormat YYYY-MM-DD
    section Build
    First :a1, 2026-01-01, 15d
    Second :a2, after a1, 15d
"""

def render(source, *args):
    result = subprocess.run([cli, *args], input=source, text=True,
                            capture_output=True, check=True)
    return result.stdout

def width(output):
    return max((display_width(line) for line in output.splitlines()), default=0)

for encoding in ((), ("--ascii",)):
    widths = [width(render(gantt, *encoding, "--width", str(size)))
              for size in (60, 100, 120)]
    assert widths == [60, 100, 120], widths
    assert width(render(gantt, *encoding)) == 80
    assert width(render(gantt, *encoding, "--width", "120", "--no-auto-fit")) == widths[2]
    print(f"Gantt {encoding or 'Unicode'} widths: {widths}")

title = "CopyPaste MVP — proceed branch only"
long_gantt = f"""gantt
    title {title}
    dateFormat YYYY-MM-DD
    vert 2026-01-16
    section 研究と検証
    Accounts, devices, presence, signaling and TURN deployment :a1, 2026-01-01, 15d
    Final gate :milestone, gate, after a1, 0d
"""
for encoding, milestone in (((), "◆"), (("--ascii",), "*")):
    for size in (20, 40, 60, 80, 100, 120):
        output = render(long_gantt, *encoding, "--width", str(size))
        assert width(output) <= size, (encoding, size, width(output))
        assert milestone in output, (encoding, size)
        if size >= display_width(title):
            assert title in output, (encoding, size)
    assert width(render(long_gantt, *encoding, "--width", "1")) <= 1

assert render("graph LR\n  A --> B\n", "--width", "100")
PY
  '';

  meta = {
    description = "Render Mermaid diagrams in your terminal or Python app";
    homepage = "https://github.com/fasouto/termaid";
    license = lib.licenses.mit;
    mainProgram = "termaid";
  };
}
