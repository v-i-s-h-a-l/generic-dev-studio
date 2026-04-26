#!/usr/bin/env bash
# Fixture: opt-out marker — should pass.
# lint-build:allow next-line — debugging tool, runs once
xcodebuild test -scheme Foo
