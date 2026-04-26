#!/usr/bin/env bash
# Fixture for lint-build-invocations.sh — must be flagged as a violation.
xcodebuild build -scheme Foo -destination "platform=iOS Simulator,name=iPhone 15"
