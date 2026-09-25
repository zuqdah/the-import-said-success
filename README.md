# the-import-said-success

A managed solution promoted into a Power Platform environment, over a component
somebody had edited there — where the import **reports success**, the solution
version **advances**, and the component **does not change**.

## The problem

Someone opens the target environment and edits a managed component. A field
label, a flow step, one line of a config web resource. It takes ten seconds and
nobody writes it down.

That edit creates an **unmanaged layer**, and from then on every import of that
solution leaves the component alone. Not with an error — the import succeeds.
The solution version advances. The pipeline goes green. The component serves the
hand edit, and will keep serving it through every release until somebody
notices.

What makes this worth a lab is that **the two signals people actually check
both say the deployment worked**:

- *Did the import succeed?* Yes. HTTP 204, no warning.
- *Is the right version deployed?* Yes. The target reports the new version.

## What this proves

A real dev → target promotion, twice, graded against expectations declared
before the run:

| pass | `OverwriteUnmanagedCustomizations` | |
|---|---|---|
| `default` | `false` | what every import does unless somebody knew to change it |
| `overwrite` | `true` | the documented remediation |

| | |
|---|---|
| Guards | 2, each graded in both passes |
| Assertions about the observable signals | 3 |
| Declared in | [`layer-matrix.json`](layer-matrix.json), written before the run |
| Result | **7/7 as declared** |
| Cost | nothing — two free Developer environments |

The baseline guard exists so the finding means something. Without observing an
import that *does* land, a drill reporting `Suppressed` for everything — which
is what a broken value read looks like — would pass the finding for free.

## The result

```
== default pass (OverwriteUnmanagedCustomizations = False)
  baseline-import-applies            Applied
  import-over-unmanaged-layer        Suppressed
  import reported success: True (HTTP 204)
  solution version advanced 1.0.0.1 -> 1.0.0.2
  layer rows for the component: 0

== overwrite pass (OverwriteUnmanagedCustomizations = True)
  baseline-import-applies            Applied
  import-over-unmanaged-layer        Applied
  import reported success: True (HTTP 204)
  solution version advanced 1.0.0.1 -> 1.0.0.2
  layer rows for the component: 0
```

**Read the two passes side by side.** The import succeeded in both. The version
advanced in both. Zero layer rows in both. The *only* difference is whether the
component changed — and nothing in the import output, the version number, or the
layers table distinguishes them.

That is the finding: one flag, defaulting to off, separates a deployment that
worked from one that reported working.

## Why the evidence has to be the component, not the import

`Resolve-ImportOutcome` takes three inputs — what the solution **shipped**, what
the target served **before**, and what it serves **after** — and deliberately
does *not* take the import's own success as evidence:

| outcome | meaning |
|---|---|
| `Applied` | the target serves what the solution shipped |
| `Suppressed` | the import reported success and the target still serves the previous value |
| `Failed` | the import itself failed. A visible error, and not what this lab is about |
| `Unknown` | could not be determined. Always a failure, never a pass |

A successful import that changed nothing is the entire subject here, so a
function treating the import result as evidence of application would be
structurally incapable of seeing it.

All of that judgement lives in
[`SolutionLayers`](module/SolutionLayers/SolutionLayers.psm1), which makes no
call to Dataverse and is covered by 32 unit tests.

## The three ways you would try to notice, and why none work

Declared as assertions rather than guards, because they are not outcomes of an
import — they are the things somebody would check.

**The import reports success.** In both passes. No error, no warning, no
non-zero status, so a pipeline gating on "did the import succeed" learns
nothing.

**The solution version advances.** In both passes, including the one where the
component did not move. This is the check most teams actually perform — *is the
right version deployed?* — and it answers yes over a stale component. A green
version is not evidence.

**`msdyn_componentlayers` returned zero rows**, with a demonstrable unmanaged
layer present. This assertion is marked **Uncertain** in the matrix on purpose:
it is what was observed and not what is understood. It may be a query mistake, a
component type the table does not cover, or asynchronous population. It is
declared so that if it ever starts returning rows, this lab fails and says so
rather than repeating a claim that stopped being true.

## Cost

**Nothing.** Two free Developer environments, and Developer SKU **cannot attach
to a pay-as-you-go billing policy**, so they are structurally incapable of
billing rather than merely cheap. There is no billing policy in the tenant at
all.

The environments **persist** between runs, which is a deliberate deviation from
the rest of this series. Deleted Power Platform environments sit in a
recently-deleted state holding tenant capacity for days, so creating and
destroying one per run would eventually fail for a reason unrelated to the lab —
and Dataverse provisioning takes about ten minutes each time. What the drill
creates and destroys is the **solution**, which is the thing under test.

## Running it

```bash
scripts/bootstrap.sh --dev https://yourdev.crm.dynamics.com \
                     --target https://yourtarget.crm.dynamics.com
gh workflow run drill.yml
```

The bootstrap creates a federated Entra application, adds it as an **application
user** in both environments with System Administrator, and sets the repository
variables and environment. It is re-runnable.

System Administrator is not for convenience: the drill imports *managed*
solutions and deletes them from the target between passes, and System Customizer
can import but cannot delete a managed solution. Without that reset the second
pass inherits the first one's state and a guard passes for the wrong reason.

Locally, with PowerShell 7 and the Azure CLI:

```bash
pwsh ./scripts/Invoke-LayerDrill.ps1 \
  -DevUrl https://yourdev.crm.dynamics.com \
  -TargetUrl https://yourtarget.crm.dynamics.com
```

If the machine has no PowerShell 7 — the one this was written on has 5.1 only —
[`dev/controller.Dockerfile`](dev/controller.Dockerfile) builds one with `pwsh`
and `az`. Note that the container **cannot** use a mounted CLI token cache; see
below. Fetch the tokens on the host and pass them in:

```bash
docker build -f dev/controller.Dockerfile -t layer-controller dev
docker run --rm \
  -e DATAVERSE_DEV_TOKEN="$(az account get-access-token --resource https://yourdev.crm.dynamics.com/ --query accessToken -o tsv)" \
  -e DATAVERSE_TARGET_TOKEN="$(az account get-access-token --resource https://yourtarget.crm.dynamics.com/ --query accessToken -o tsv)" \
  -v "$PWD:/lab" -w /lab layer-controller \
  pwsh -File scripts/Invoke-LayerDrill.ps1 -DevUrl … -TargetUrl …
```

## Bugs the build found in itself

**A `[string]` parameter turned a missing value into an empty one.** The module
grades an unread value as `Unknown` so that a failed measurement cannot pass —
except a `[string]` parameter in PowerShell coerces `$null` to `''`, so
`$null -eq $Shipped` was never true and the check was dead code. Two unread
values then compared equal and graded `Suppressed`. Caught by the two tests
written for exactly that case, and fixed by typing the parameters `[object]`.

The distinction matters beyond the bug: an empty web resource is a value a
solution can legitimately ship, so *absent* and *empty* have to stay different
things.

**A hand-built managed solution is not importable.** The first design had one
environment and a crafted solution zip with `<Managed>1</Managed>`. Three
attempts, three different errors, ending with Dataverse saying to *"import again
using the XML file that was generated when you exported the solution"*. So the
lab does a real promotion: built unmanaged in dev, exported managed, imported to
the target. Ten minutes well spent — the alternative was discovering it
mid-drill.

**`ImportSolution` requires `ImportJobId`.** Omitting it returns a payload error
naming the missing parameter, which reads like a malformed request rather than a
required field.

**A mounted Azure CLI token cache does not work in a Linux container.** On
Windows the CLI's MSAL cache is DPAPI-encrypted against the Windows user, so a
container with `~/.azure` mounted can read `azureProfile.json` but cannot
decrypt a token: `az account show` **succeeds** and
`az account get-access-token` fails with *"does not exist in MSAL token cache"*.
Those two disagreeing is a confusing pair. The drill now takes tokens from the
environment first, which also lets CI supply one from a federated credential.

**My own error suppression cost a debugging round trip.** The first version
fetched tokens with `2>$null` and reported "could not get a token" without
saying why — for a message the CLI had already produced. Errors are captured and
reported now.

**`az rest --method patch` fails on Windows** with *"--headers was unexpected at
this time"*, a cmd.exe parsing artifact with nothing to do with the request.
The drill fetches a token and uses `Invoke-RestMethod` directly, which is
better anyway: a non-2xx is data rather than an exception, and "the import
returned success" is something this lab records rather than infers.

## Status

| | |
|---|---|
| Unit tests | 32, green, no Dataverse environment required |
| PSScriptAnalyzer, `shellcheck`, `actionlint` | clean |
| Live drill | **7/7 as declared, 0 failed, 0 inconclusive** |
| Environments | two free Developer SKUs, persistent by design |
| Cost | $0, and structurally incapable of billing |

## What this does not do

**One component type.** A text web resource, because the layering mechanism is
identical for a canvas app, a flow or a form, and a web resource's content can
be read back in one call and compared exactly. A flow would make the same point
less legibly.

**It does not remove the unmanaged layer.** `RemoveActiveCustomizations` is not
exposed in the Web API (404), and the maker portal's "remove unmanaged layer" is
a click. The remediation this lab proves is the import flag, which is the one a
pipeline can actually set.

**It does not cover environment variables or connection references**, which are
the other classic way a promotion silently keeps dev values. Same family of
problem, different mechanism, and worth their own drill.

**Two environments, not a real ALM chain.** No build pipeline, no solution
checker gate, no multi-stage promotion. `copilot-studio-alm` covers the
promotion pipeline itself; this lab is only about whether the thing you promoted
arrived.
