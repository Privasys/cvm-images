# Security Policy

## Reporting a Vulnerability

We take security seriously at Privasys. If you discover a vulnerability
in cvm-images, please report it responsibly through one of the
following channels:

- **Email:** [security@privasys.org](mailto:security@privasys.org)
- **GitHub:** Open a [private security advisory](https://github.com/Privasys/cvm-images/security/advisories/new)

Please include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 48 hours and aim to provide a fix or
mitigation within 7 days for critical issues.

## Scope

This policy covers:

- The mkosi build configuration and overlay files in this repository
- The resulting disk image produced by `mkosi build`
- The GitHub Actions CI/CD pipeline

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅        |
