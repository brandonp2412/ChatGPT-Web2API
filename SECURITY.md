# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Sloppa, please report it responsibly:

1. **Do not open a public issue** for security vulnerabilities
2. Email security concerns to the maintainers via GitHub's private vulnerability reporting
3. Include: description, steps to reproduce, potential impact

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 0.2.x   | ✅ Active |
| 0.1.x   | ❌ End of life |

## Security Considerations

This project drives a real Chrome browser connected to your ChatGPT account:

- **Auth cookies** are stored locally in the Chrome profile directory
- **No credentials are transmitted** to any third-party server
- **All API traffic** stays between your code and your local Chrome instance
- **The proxy binds to `127.0.0.1`** by default — not exposed to the network
- **Cookie injection** for Docker deployments should use secrets management, not plaintext files
