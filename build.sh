#!/usr/bin/env bash
set -e

# Installer Flutter (version stable) dans le répertoire de build
git clone https://github.com/flutter/flutter.git --depth 1 -b stable flutter_sdk
export PATH="$PWD/flutter_sdk/bin:$PATH"

flutter --version
flutter config --enable-web

flutter pub get
flutter build web --release