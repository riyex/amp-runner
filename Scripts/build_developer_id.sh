#!/bin/sh
# Builds the primary (Developer ID / direct distribution) target.
# Signing, notarization, and packaging are separate manual steps — see ARCHITECTURE.md.
set -eu

cd "$(dirname "$0")/.."

./Scripts/generate_project.sh

xcodebuild \
    -project AmpRunner.xcodeproj \
    -scheme AmpRunner \
    -configuration Debug \
    build
