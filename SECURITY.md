# Security

## Reporting a vulnerability

Please email bugbounty@databricks.com to report any security vulnerabilities. We will acknowledge receipt of your vulnerability and strive to send you regular updates about our progress. If you're curious about the status of your disclosure please feel free to email us again.

## Secrets in this repository

There are none, by design: source database logins, connection passwords and cloud keys stay in files outside the repo (`*.local.sh` is git-ignored) and reach commands through their environment ([secret-handling](skills/secret-handling/SKILL.md)). Test records hold outcomes, counts, versions and error text only; `record.py` refuses a record that looks like it holds an IP, hostname, ID, email, workspace name or credential. If you find a secret in a commit, report it as above.
