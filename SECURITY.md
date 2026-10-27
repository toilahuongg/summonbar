# Security Policy

Summonbar runs coding agents that can read and edit files and run commands, so security bugs matter here. Examples: a way for a project, extension or `.claude` command to run something without the user asking; leaking prompts, environment variables or tokens; or bypassing an agent's permission or sandbox arguments.

## Reporting a vulnerability

Please **don't open a public issue.** Report it privately through [GitHub's private vulnerability reporting](https://github.com/toilahuongg/summonbar/security/advisories/new) with the steps to reproduce and what an attacker could do.

You'll get a reply within a few days. Once a fix is released the advisory is published, with credit to you unless you'd rather stay anonymous.

## Supported versions

Only the latest `main` is supported.
