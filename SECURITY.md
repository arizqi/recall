# Security policy

## Supported versions

Recall is early-stage software. Security fixes are made on the latest `main`
branch only.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not open a
public issue containing credentials, conversation text, account-export content,
or identifying local filesystem paths. If private reporting is unavailable, open
a minimal public issue asking the maintainer for a private contact channel.

Include the affected commit, reproduction steps using synthetic data, impact,
and any suggested mitigation. Reports are reviewed as maintainer availability
permits.

## Privacy-sensitive reports

Recall indexes private local data. Before sharing logs or fixtures, remove message
content, names, email addresses, tokens, conversation IDs, and home-directory
paths. Never upload an `index.db` or an unredacted account export.
