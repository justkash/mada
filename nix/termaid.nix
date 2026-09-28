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

  build-system = [ python3Packages.hatchling ];

  # Tests need pytest-snapshot and other dev deps that aren't packaged here.
  doCheck = false;
  pythonImportsCheck = [ "termaid" ];

  meta = {
    description = "Render Mermaid diagrams in your terminal or Python app";
    homepage = "https://github.com/fasouto/termaid";
    license = lib.licenses.mit;
    mainProgram = "termaid";
  };
}
