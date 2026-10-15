# HTTPS Interception

Burp Suite intercepts HTTPS traffic by acting as a man-in-the-middle with
its own Certificate Authority. For Chromium (via Playwright MCP) to trust
Burp's CA, the CA certificate must be imported into an isolated NSS
trust store.

> **Security note**: Do not disable TLS verification. Do not use
> `curl -k` or `ignoreHTTPSErrors`. The configuration below maintains
> full certificate chain verification with Burp's CA as the trusted root.

## Exporting the Burp CA in DER format

1. In Burp, go to **Proxy > Options > Import / export CA certificate**.
2. Select **Certificate in DER format**.
3. Save as `~/tools/playwright/burp-ca.der`.

Or copy from the Burp installation:

```bash
cp ~/.BurpSuite/burp-ca.der ~/tools/playwright/burp-ca.der
```

## Converting DER to PEM using OpenSSL

```bash
openssl x509 \
  -inform DER \
  -in ~/tools/playwright/burp-ca.der \
  -outform PEM \
  -out ~/tools/playwright/burp-ca.pem
```

Verify:

```bash
openssl x509 -in ~/tools/playwright/burp-ca.pem -noout -subject -fingerprint -sha256
```

## Configuring an isolated NSS trust database

Chromium uses an NSS database for certificate trust. Create an isolated
database:

```bash
NSS_DIR=~/tools/playwright/isolated-home/.pki/nssdb
mkdir -p "$NSS_DIR"

# Initialize empty database
certutil -N --empty-password -d "sql:$NSS_DIR"
```

## Importing the Burp CA using certutil

```bash
certutil -A \
  -d "sql:$NSS_DIR" \
  -n "Burp Suite CA" \
  -t "C,," \
  -i ~/tools/playwright/burp-ca.pem
```

The trust flags `C,,` mean:

- `C`: Trusted for issuing server certificates (SSL).
- Empty: Not trusted for email.
- Empty: Not trusted for code signing.

Verify the import:

```bash
certutil -L -d "sql:$NSS_DIR"
```

## Configuring the dedicated Playwright launcher

The launcher (`~/tools/playwright/start-mcp.sh`) sets the isolated `HOME`
so that Chromium picks up the NSS database at:

```
~/tools/playwright/isolated-home/.pki/nssdb/cert9.db
```

No additional Chromium flags are needed; Chromium automatically uses
`$HOME/.pki/nssdb` for certificate storage.

## Testing HTTPS using curl with --cacert

```bash
curl --fail --silent --show-error \
  --noproxy "" \
  --proxy http://127.0.0.1:8080 \
  --cacert ~/tools/playwright/burp-ca.pem \
  "https://example.com/"
```

Expected: HTTP 200 with full certificate chain verification against
Burp's CA.

## Confirming HTTPS traffic through Playwright and Burp

1. Start Burp (`scripts/start-burp.sh`).
2. Start the Playwright MCP (or verify it is connected):

   ```bash
   opencode mcp list
   ```

3. In an OpenCode session, navigate to `https://example.com/`.
4. In Burp, go to **Proxy > HTTP history**.
5. Verify the request appears with the full HTTPS content visible.

If the page fails to load with a certificate error:

- Verify the NSS database exists and contains the Burp CA.
- Verify the launcher is using the isolated `HOME`.
- Check `certutil -L -d "sql:$NSS_DIR"` output.

## Security safeguards

- The Burp CA private key never leaves the VM.
- The NSS database is isolated to the Playwright MCP subprocess.
- No system-wide certificate trust is modified.
- `.gitignore` excludes `burp-ca.*`, `.pki/`, `nssdb/`, and
  `browser-profile/`.
- Do not commit the real Burp CA, private keys, or browser profile.

## Re-running the setup

The setup script (`~/tools/playwright/setup-burp-https.sh`) is idempotent:

```bash
bash ~/tools/playwright/setup-burp-https.sh
```

It re-imports the CA, updates the launcher, and validates the OpenCode
configuration. It backs up the existing OpenCode config before modifying
it.
