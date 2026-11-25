#!/bin/bash
set -euo pipefail

release_script="$(cd "$(dirname "$0")/../Scripts" && pwd)/release.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
cd "${fixture_dir}"
mkdir -p iMCP.app bin downloads
echo fixture > iMCP.app/fixture

# Copy the files passed to gh into an empty download directory.
cat > bin/gh <<'EOF'
#!/bin/bash
set -eu
[[ $# -eq 5 && $1 == release && $2 == upload && $3 == "${VERSION}" && $5 == --clobber ]]
cp "$4" downloads/
EOF
chmod +x bin/gh

run_release() {
  env -i PATH="${fixture_dir}/bin:/usr/bin:/bin" VERSION=0.0.1 \
    /bin/bash "${release_script}" "$1"
}

run_release package
run_release upload
cd downloads
cmp ../dist/iMCP-0.0.1.zip iMCP.zip
cmp ../dist/iMCP-0.0.1.zip.sha256 iMCP.zip.sha256
shasum -a 256 iMCP.zip | cmp - iMCP.zip.sha256
shasum -a 256 -c iMCP.zip.sha256
