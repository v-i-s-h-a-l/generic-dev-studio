# Studio v2 Build and Release Messages

A11 standardizes product-facing build and release message drafts. This guide is
for message shape only; it does not send Slack posts, upload builds, tag
releases, or compare against historical build threads.

## Headlines

TestFlight messages start with:

```text
[iOS] build <number> is available on TestFlight
```

App Store submission messages start with:

```text
[iOS] v<version> (build <number>) has been submitted for App Store review
```

Use exactly one headline as the first non-empty line.

## Sections

Use these section headings and omit empty sections:

```text
*New*
*Fixed*
*Crash fixes*
```

Each section body uses bullets that start with `- ` or `• `. Keep bullets
user-visible and non-duplicative within the same message.

## Duplicate Rule

`scripts/lint-build-release-message.sh` catches duplicates inside one draft:

- repeated section headings;
- repeated normalized bullets.

Cross-build history comparison is intentionally out of scope for this leaf.
Future release-manager work can compare against prior TestFlight/App Store
messages using release-packet context.
