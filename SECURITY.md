# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security** tab → **Report a vulnerability**
([private vulnerability reporting](https://github.com/SmailG/voice-conversation/security/advisories/new)).
Do not open a public issue for a vulnerability.

You can expect a first response within a week.

## Scope

voice-conversation runs entirely on your Mac: a launchd service listening on `127.0.0.1` only (it refuses requests addressed to any other
host name, which blocks DNS rebinding from web pages), hooks
that forward Claude Code's reply text to it, and the `/speak` command. Relevant reports include
anything that lets a web page or a remote host drive the service, command injection through
`/speak` arguments or reply text, and ways to make the hooks block or break a Claude Code session.

Out of scope: other accounts on the same Mac. The service has no authentication between local
users, so anyone logged in to the Mac can send it requests (speak text, stop speech, transcribe
audio). It is built for a single-user Mac.

Only the latest release is supported.
