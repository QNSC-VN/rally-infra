# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest (`main`) | ✅ |
| older releases | ❌ — please upgrade |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report security issues by emailing: **security@rally-app.io**

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (optional)

You will receive an acknowledgement within **48 hours** and a status update within **7 days**.

## Disclosure Policy

- We follow [responsible disclosure](https://en.wikipedia.org/wiki/Responsible_disclosure).
- Once a fix is released, we will publish a security advisory on GitHub.
- Credit will be given to the reporter unless anonymity is requested.

## Scope

In scope:
- Misconfigured IAM roles or OIDC trust policies allowing unintended AWS access
- State file exposure (S3 bucket misconfigurations)
- Sensitive values leaking via plan output or CI logs

Out of scope:
- Denial of service attacks
- Social engineering
- Issues requiring physical access to AWS console
