# Security policy

Earshot records audio and keeps transcripts of private conversations, so security and privacy bugs matter more here than in most apps.

## Reporting a vulnerability

**Do not open a public issue.** Report it privately through GitHub: the repository's **Security** tab › **Report a vulnerability** ([direct link](https://github.com/bradwasf/earshot/security/advisories/new)). Only the maintainer can see the report.

Please include what is affected, how to reproduce it, and what an attacker could do. Expect a first reply within a week. Fixes go into the next release, and reporters are credited in the advisory unless they prefer not to be.

## What counts

Examples of what we want to hear about:

- Audio, transcript or summary text leaving the Mac in any way other than an export the user chose for that call.
- Transcript text written anywhere other than the calls folder (for example into the log).
- Weaknesses in how the Slack webhook URL is stored or validated.
- Ways another app or a web page could start a recording or read calls through Earshot.

## Supported versions

Only the latest release gets security fixes.
