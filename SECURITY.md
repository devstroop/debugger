# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ |
| < 0.1   | ❌ |

## Reporting a Vulnerability

If you discover a security vulnerability in debugger-mcp, **do not open a public issue.** Instead:

1. **Email** the maintainer at the address listed in the
   [GitHub repo's About section](https://github.com/devstroop/debugger-mcp).
2. Include:
   - Description of the vulnerability
   - Steps to reproduce (build command + payload if applicable)
   - Affected platform(s) and Zig version
   - Any proposed fix (if you have one)

### What to expect

| Stage | Timeline |
|-------|----------|
| Acknowledgment | Within 48 hours |
| Triage & initial assessment | Within 1 week |
| Fix released | Depends on severity — critical within days, moderate within 2 weeks |

### Scope

The following are **in scope**:
- Memory safety issues (buffer overflows, use-after-free, double-free)
- Arbitrary code execution via malformed DAP messages
- Denial-of-service via malicious stdin/MCP input
- Credential leakage through debugger launch arguments

The following are **out of scope**:
- Issues in codelldb or LLDB (report upstream)
- Issues in the MCP client (OpenCode, Cline, etc.)
- Bugs that require physical access to the victim's machine
- Social engineering attacks

## Disclosure Policy

We follow coordinated disclosure. Please give us reasonable time to fix the issue before disclosing it publicly. We will credit reporters in the release notes unless anonymity is requested.
