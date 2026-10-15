# AI Security Assessment Roadmap

This document outlines the intended future workflow for AI-assisted
security assessments on authorized targets.

> **All testing is strictly limited to authorized bug-bounty / VDP
> programs. Explicit written authorization is required before any
> testing begins.**

## Workflow

```
Authorized target
       │
       ▼
Scope validation ───────► Confirm target is in-scope for the program
       │
       ▼
Reconnaissance ────────► Passive and active recon within scope
       │
       ▼
Browser mapping ────────► Map attack surface via Playwright + Burp
       │
       ▼
Controlled vuln testing ► Test specific vulnerability classes
       │
       ▼
Evidence collection ────► Screenshots, request/response pairs, PoCs
       │
       ▼
Reporting ──────────────► Structured report with findings and remediation
```

## Agent roles

OpenCode supports assigning different models to specialist agents.
The following roles are planned:

| Role | Responsibility | Tools |
| --- | --- | --- |
| Orchestrator | Plan and coordinate assessments | OpenCode |
| Recon agent | Subdomain enumeration, port scanning, technology fingerprinting | subfinder, httpx, amass |
| Browser mapping agent | Map web application attack surface | Playwright MCP, Burp proxy |
| Web security testing | Test for OWASP Top 10 and other web vulnerabilities | Burp Suite, nuclei, ffuf |
| Source-code review | Review source code for vulnerabilities | grep, rg, code analysis |
| Verification | Verify findings and eliminate false positives | Burp Repeater, curl |
| Reporting | Generate structured assessment reports | Markdown, templates |

Different models may be assigned to specialist agents when supported by
the OpenCode provider.

## CLI tool integration

OpenCode should be able to select and execute approved CLI security
tools dynamically. Not every tool requires an MCP integration.

Examples of CLI tools that can be executed directly:

```bash
# Reconnaissance
subfinder -d target.example.com
httpx -l subdomains.txt -status-code -title

# Vulnerability scanning
nuclei -u https://target.example.com -t technologies/

# Directory brute-forcing
ffuf -u https://target.example.com/FUZZ -w wordlist.txt

# HTTP probing
curl -X POST https://target.example.com/api/endpoint -d '{"test":"data"}'
```

The agent selects the appropriate tool based on the task. MCP
integrations are used for tools that require persistent state or complex
interaction (e.g., Burp Suite, browser automation).

## Authorization requirements

Before any testing begins:

1. **Explicit authorization**: Written permission from the asset owner
   (bug-bounty program enrollment, VDP scope, or private engagement
   authorization).
2. **Allowlist**: A clear list of in-scope targets (domains, IP ranges,
   APIs).
3. **Exclusions**: A list of out-of-scope targets and prohibited actions
   (e.g., DoS testing, social engineering, physical security).
4. **Rate limits**: Agreed-upon request rates to avoid service disruption.
5. **Approval for intrusive operations**: Active scanning, exploitation,
   and data exfiltration testing require explicit per-operation approval.

## Safety guardrails

- **Scope enforcement**: All tool calls are validated against the
   allowlist before execution. Out-of-scope targets are rejected.
- **Rate limiting**: Automated tools must respect configured rate limits.
- **Data handling**: Captured data is stored locally on the VM and
   never committed to Git. Sensitive findings are reported through
   authorized channels only.
- **Kill switch**: The orchestrator can immediately halt all testing
   if scope violations or unexpected behavior are detected.
- **Logging**: All tool executions are logged for audit purposes.

## Current status

**This infrastructure update does not implement autonomous scanning.**
The current phase focuses on:

- Documenting the existing Burp Suite, Playwright, and OpenCode setup.
- Establishing reproducible configuration management.
- Creating health checks and operational scripts.

Future phases will implement:

- Scope validation tooling.
- Recon agent automation.
- Browser mapping workflows.
- Vulnerability testing playbooks.
- Evidence collection and reporting templates.

## Compliance

All testing must comply with:

- The target's bug-bounty / VDP program rules.
- Applicable computer fraud and abuse laws (CFAA, etc.).
- The cloud provider's acceptable use policy.
- Data protection regulations (GDPR, CCPA) if personal data is
   encountered.
