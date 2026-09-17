# Choose your Company OS path

Company OS has three supported setup paths. Choose the job you are doing before
you install anything; their prerequisites and execution authority are
deliberately different.

| Profile | Choose it when | Execution owner |
|---|---|---|
| Default Docker companion | You want the Workspace and ledger alongside Codex or Claude | The connected host session |
| Secured local native workers | You want Company OS to execute bounded native agent work | Company OS through the isolated credential gateway |
| Source development | You are changing Company OS itself | The developer-configured local runtime |

The supported product runtime is `hsm_console` plus the Company Console and
PostgreSQL ledger. Legacy binaries and their startup instructions are not an
onboarding path.

## Default Docker companion

Use this for the fastest safe install. Docker is the only prerequisite for this
profile. The installer pulls an image, provisions the database authority lanes,
starts the API and Console, and opens the Workspace start page.

```bash
curl -fsSL https://raw.githubusercontent.com/HSM-II/company-os-install/main/install.sh | bash
```

The default profile is `companion`. It does not request a provider key or
preselect a model. The start page remains UI-only until a backend confirms an
execution lane. Host-managed work happens in a connected Codex or Claude Code
session; do not treat a visible Run button or an HTTP health response as proof
that native model execution is available.

Connect that session with one command, run inside the project you work in:

```bash
npx --yes @hsm/company-os-mcp-server connect claude   # or: connect codex
```

It runs the same installer when the stack is missing, then writes `.mcp.json`
(Claude Code) or a managed `[mcp_servers.company-os]` block in
`.codex/config.toml` (Codex). Neither file receives a credential. Reload the
agent and ask it to start the Company Passport; commissioning creates a
distinct `claude-code` or `codex` company agent with bounded 30-day scopes and
stores its credentials in private `0600` files under `~/.hsm-ii`. Add
`--no-start` to only regenerate the host configuration. Any other MCP host can
register the same stdio server directly (see the README).

First success means:

1. the Console opens at `http://127.0.0.1:3050/workspace/start`;
2. the API and Workspace readiness checks are healthy;
3. the start page truthfully reports UI-only or a verified execution lane; and
4. a host-managed continuation can read the selected company without receiving
   a provider credential from Company OS.

From a repository checkout, the non-mutating first-run check is:

```bash
bash scripts/company-os-first-run-check.sh
```

The public installer options are:

| Option | Meaning |
|---|---|
| `--dir PATH` | Choose the installation directory; default is `~/.hsm-ii` |
| `--image REF` | Select the runtime image; supported non-development installs resolve to an immutable digest |
| `--profile NAME` | Select `companion`, `full`, or `dev`; default is `companion` |
| `--no-start` | Write configuration without starting the stack; non-development use requires an immutable image reference |
| `--no-open` | Do not open the browser after startup |
| `--credential-gateway` | Route the supported native provider through the isolated local gateway |
| `--provider-key-file PATH` | Supply the private OpenRouter key file for a fresh gateway installation |
| `--uninstall` | Stop this installation while retaining its data volumes |

Run `bash install.sh --help` from a checkout for the executable source of this
option list.

## Secured local native workers

Use this only when Company OS itself must run native agent work. This path adds
an isolated OpenRouter credential gateway, a selected model, explicit bounded
tools, spend/admission controls, and receipt verification. It is not evidence
for unattended shared multi-tenant hosting.

Prerequisites are Docker, a reviewed immutable Company OS image, a source
checkout containing the installer and gateway overlay, an explicitly selected
model, and a private OpenRouter key file. Keep the provider key out of commands,
`.env`, tasks, prompts, and chat messages.

```bash
chmod 600 /absolute/path/to/openrouter-key
DEFAULT_LLM_MODEL='your-selected-model-id' \
bash install.sh \
  --profile full \
  --credential-gateway \
  --provider-key-file /absolute/path/to/openrouter-key \
  --dir /absolute/path/to/company-os-install \
  --image ghcr.io/permutationresearch/company-os@sha256:YOUR_RELEASE_DIGEST \
  --no-open
```

First success means a bounded native task reaches a terminal state through the
gateway and the Console shows the matching run, tool, spend, and verification
receipts. A healthy gateway or model-list response alone is insufficient.

Use the complete [secured local deployment
contract](company-os/SECURED_LOCAL_DEPLOYMENT.md) for credential isolation,
supported tools, exact-image proof, recovery, and rollback.

## Source development

Use this path when changing the Rust runtime, API, migrations, Console, or test
harness. This profile requires Rust, Node.js 20+, PostgreSQL, and model access
for any executed agent turn. Docker may provide PostgreSQL; an explicit
`HSM_COMPANY_OS_DATABASE_URL` may point at a developer-owned database instead.

```bash
git clone https://github.com/PermutationResearch/HSM-II.git
cd HSM-II
bash scripts/company-os
```

The friendly launcher builds or starts `hsm_console`, starts the Company
Console, waits for API and AgentChat runtime readiness, and opens
`/workspace/start`. `scripts/company-os-up.sh` is the low-level operator path
for startup diagnostics.

Useful commands:

```bash
bash scripts/company-os --status
bash scripts/company-os --no-open
bash scripts/company-os --force-restart
bash scripts/company-os --smoke
bash scripts/company-os --stop
```

First success means both endpoints answer and the runtime response accurately
identifies whether the selected provider is executable:

```bash
curl -sfS http://127.0.0.1:3847/api/company/health
curl -sfS http://127.0.0.1:3050/api/agent-chat-runtime
```

If the runtime is unavailable, configure a supported provider for the developer
profile and rerun the readiness check. Do not weaken the companion or secured
profile to make a development configuration appear ready.

## What to do after setup

1. Open `/workspace/start` and create or select a company.
2. Keep UI-only selected unless the page confirms the execution lane you intend
   to use.
3. Create a bounded task with an observable completion condition.
4. Execute it only through the owner for the chosen profile.
5. Verify the resulting state and immutable receipts; a successful transport
   response is not completion evidence.

For deeper operation and development details, use:

- [Company OS operator guide](company-os/HSM_II_COMPANY_OS_OPERATOR_GUIDE.md)
- [Workspace and AgentChat source launch](company-os/COMPANY_OS_AGENT_CHAT_LAUNCH.md)
- [Canonical product path](company-os/CANONICAL_PRODUCT_PATH.md)
- [System threat and abuse model](security/company-os-threat-model.md)

## Troubleshooting

| Symptom | Meaning and next action |
|---|---|
| Start page says UI-only | No verified provider lane is selected; continue in Codex/Claude or configure the intended non-companion profile |
| Selected provider is blocked | Follow the named readiness action; do not repeatedly submit the task |
| `401` from Company OS | Use the installation's transport bearer and the required principal/delegation; do not interchange credential classes |
| Docker is unavailable | Start Docker Desktop/Engine and rerun the installer |
| PostgreSQL fails in source development | Start the developer-owned database and verify all configured Company OS role URLs |
| A secured native task cannot reach the provider | Inspect gateway health and safe status logs; never move the upstream key into the API environment |
