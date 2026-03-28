#!/bin/bash
set -eo pipefail

echo "==> Building openclaw macOS standalone installer"

# 1. Determine architecture and set Node version
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  NODE_ARCH="arm64"
elif [ "$ARCH" = "x86_64" ]; then
  NODE_ARCH="x64"
else
  echo "Unsupported architecture: $ARCH"
  exit 1
fi

NODE_VERSION="v22.16.0"
NODE_TARBALL="node-${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"

# Set up paths
WORK_DIR=$(mktemp -d)
PKG_ROOT="$WORK_DIR/pkg-root"
PKG_SCRIPTS="$WORK_DIR/pkg-scripts"
OPT_OPENCLAW="$PKG_ROOT/opt/openclaw"

# Extract version from package.json using robust node -p
VERSION=$(node -p "require('./package.json').version")

echo "==> Version: $VERSION"
echo "==> Architecture: $ARCH ($NODE_ARCH)"

# Ensure we clean up temp directory on exit
trap 'rm -rf "$WORK_DIR"' EXIT

# 2. Pack OpenClaw
echo "==> Packing openclaw..."
# Remove any existing tarballs to avoid conflicts
rm -f openclaw-*.tgz
pnpm pack

# Retrieve the exact tarball name
TGZ_FILE=$(ls openclaw-*.tgz | head -n 1)
if [ -z "$TGZ_FILE" ]; then
  echo "Error: Could not find packed tarball."
  exit 1
fi

# 3. Set Up Staging Directory
mkdir -p "$OPT_OPENCLAW"
mkdir -p "$PKG_SCRIPTS"

# 4. Download and Extract Node.js
echo "==> Downloading Node.js $NODE_VERSION..."
curl -fsSLO "$NODE_URL"
echo "==> Extracting Node.js..."
tar -xzf "$NODE_TARBALL" -C "$OPT_OPENCLAW" --strip-components=1
rm -f "$NODE_TARBALL"

# 5. Install OpenClaw into Staging
echo "==> Installing openclaw into staging payload..."
# Use the bundled npm to install the local tarball
"$OPT_OPENCLAW/bin/npm" install -g "./$TGZ_FILE" --prefix "$OPT_OPENCLAW"

# 6. Clean Up Unnecessary Binaries
echo "==> Cleaning up bundled Node binaries (npm, npx, corepack)..."
# Retain npm, npx, and corepack binaries (no removal)
# rm -f "$OPT_OPENCLAW/bin/npm" "$OPT_OPENCLAW/bin/npx" "$OPT_OPENCLAW/bin/corepack"
# rm -rf "$OPT_OPENCLAW/lib/node_modules/npm"
# rm -rf "$OPT_OPENCLAW/lib/node_modules/corepack"

# 6.5 Replace openclaw symlink with an absolute path wrapper
echo "==> Creating explicit node wrapper script..."
rm -f "$OPT_OPENCLAW/bin/openclaw"
cat << 'EOF' > "$OPT_OPENCLAW/bin/openclaw"
#!/bin/bash
# Forces the use of the bundled openclaw node.js runtime
exec "/opt/openclaw/bin/node" "/opt/openclaw/lib/node_modules/openclaw/openclaw.mjs" "$@"
EOF
chmod +x "$OPT_OPENCLAW/bin/openclaw"

# 7. Create PKG Scripts
echo "==> Creating postinstall script..."
cat << 'EOF' > "$PKG_SCRIPTS/postinstall"
#!/bin/bash
# MacOS installer postinstall script
# Creates a wrapper script in /usr/local/bin to our bundled openclaw
# which sets the NODE_PATH environment variable for plugins to use our bundled SDK

TARGET_DIR="/usr/local/bin"
EXECUTABLE="/opt/openclaw/bin/openclaw"
LINK_NAME="$TARGET_DIR/openclaw"

# Ensure /usr/local/bin exists
if [ ! -d "$TARGET_DIR" ]; then
  mkdir -p "$TARGET_DIR"
  chown root:wheel "$TARGET_DIR"
  chmod 755 "$TARGET_DIR"
fi

# Create wrapper script
rm -f "$LINK_NAME"
cat << 'WRAPPER' > "$LINK_NAME"
#!/bin/bash
export NODE_PATH="/opt/openclaw/lib/node_modules${NODE_PATH:+:$NODE_PATH}"
exec "/opt/openclaw/bin/openclaw" "$@"
WRAPPER

chmod +x "$LINK_NAME"
EOF
chmod +x "$PKG_SCRIPTS/postinstall"

# 8. Build the PKG
PKG_NAME="openclaw-macos-${ARCH}-${VERSION}.pkg"
echo "==> Building package $PKG_NAME..."
pkgbuild --root "$PKG_ROOT" \
         --scripts "$PKG_SCRIPTS" \
         --identifier ai.openclaw.cli \
         --version "$VERSION" \
         --install-location / \
         "$PKG_NAME"

echo "==> Cleaning up local tarball..."
rm -f "$TGZ_FILE"

echo "==> Done! Created $PKG_NAME"
