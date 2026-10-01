#!/usr/bin/env bash
set -euo pipefail

# Netlify runs this from the repository root, alongside pubspec.yaml.
if [[ ! -f pubspec.yaml || ! -f web/index.html ]]; then
  printf '%s\n' 'Run this build from the Flutter project root (where pubspec.yaml is located).' >&2
  exit 1
fi

# Netlify does not provide Flutter by default. Use the same pinned release
# as the working application. FLUTTER_BIN is an explicit local-test override.
if [[ -n "${FLUTTER_BIN:-}" ]]; then
  flutter_bin="$FLUTTER_BIN"
else
  flutter_version="${FLUTTER_VERSION:-3.44.8}"
  sdk_dir="$PWD/.flutter-sdk/$flutter_version"
  if [[ ! -x "$sdk_dir/bin/flutter" ]]; then
    mkdir -p "$PWD/.flutter-sdk"
    git clone --depth 1 --branch "$flutter_version" \
      https://github.com/flutter/flutter.git "$sdk_dir"
  fi
  flutter_bin="$sdk_dir/bin/flutter"
fi

"$flutter_bin" --version
"$flutter_bin" precache --web
"$flutter_bin" pub get

# Client configuration is compiled into Flutter web, not read at runtime.
# Without overrides, AppConfig keeps the app's working Supabase defaults.
# Preserve URL/define arguments when this script is tested in Windows Git Bash.
# Linux (Netlify) ignores this MSYS-specific environment variable.
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}--base-href=;--dart-define="
build_args=(--release --base-href=/)
for name in SUPABASE_URL SUPABASE_ANON_KEY \
  FIREBASE_API_KEY FIREBASE_PROJECT_ID FIREBASE_MESSAGING_SENDER_ID FIREBASE_APP_ID; do
  if [[ -n "${!name:-}" ]]; then
    build_args+=("--dart-define=$name=${!name}")
  fi
done

"$flutter_bin" build web "${build_args[@]}"

# Publish the SPA fallback beside the compiled site's index.html.
cp web/_redirects build/web/_redirects

for file in index.html flutter_bootstrap.js main.dart.js _redirects; do
  if [[ ! -s "build/web/$file" ]]; then
    printf 'Missing deployment file: build/web/%s\n' "$file" >&2
    exit 1
  fi
done

printf '%s\n' 'Netlify website is ready in build/web.'
