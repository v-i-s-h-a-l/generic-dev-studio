---
name: App Store Connect JWT Generation
description: Standard pattern for generating an ASC JWT token with python3 for use in curl calls
type: reference
---

# App Store Connect JWT Generation

Generate a short-lived JWT for authenticating App Store Connect API calls.
Credentials are in `_shared/primitives/turnip-project-config.md`.

```bash
TOKEN=$(python3 -c "
import jwt, time
key = open('$(echo ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8)').read()
payload = {
    'iss': '1fa9f26b-7b13-459a-9225-1ca8d9c51fca',
    'iat': int(time.time()),
    'exp': int(time.time()) + 1200,
    'aud': 'appstoreconnect-v1'
}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': 'WJQ6D76K8R'}))
")
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
