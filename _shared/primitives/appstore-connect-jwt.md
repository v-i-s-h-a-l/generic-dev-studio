---
name: App Store Connect JWT Generation
description: Standard pattern for generating an ASC JWT token with python3 for use in curl calls
type: reference
---

# App Store Connect JWT Generation

Generate a short-lived JWT for authenticating App Store Connect API calls.
Credentials are loaded from the project-scoped release config:
`~/.dev-studio/<project>/config/release.env` and
`~/.dev-studio/<project>/secrets/appstoreconnect/`.

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
export STUDIO_RELEASE_PROJECT="<project>"
. ./scripts/lib-release-config.sh
load_release_config
ASC_KEY_PATH=$(release_asc_key_path "$STUDIO_TF_ASC_KEY_ID")
TOKEN=$(python3 - "$ASC_KEY_PATH" "$STUDIO_TF_ASC_ISSUER_ID" "$STUDIO_TF_ASC_KEY_ID" <<'PY'
import jwt, time
import sys
key_path, issuer, kid = sys.argv[1], sys.argv[2], sys.argv[3]
key = open(key_path).read()
payload = {
    'iss': issuer,
    'iat': int(time.time()),
    'exp': int(time.time()) + 1200,
    'aud': 'appstoreconnect-v1'
}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': kid}))
PY
)
```

## Curl flag note

Always use `-sg` (not just `-s`) when the URL contains square brackets (e.g. `?filter[...]`, `?fields[...]`). Without `-g`, the shell glob-expands the brackets and the request fails.

```bash
# Correct
curl -sg "https://api.appstoreconnect.apple.com/v1/builds?filter[version]=3031&..." \
  -H "Authorization: Bearer $TOKEN"

# Wrong — shell will try to glob-expand the brackets
curl -s "https://api.appstoreconnect.apple.com/v1/builds?filter[version]=3031&..." \
  -H "Authorization: Bearer $TOKEN"
```
