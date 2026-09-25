#Requires -Version 7.0

<#
    .SYNOPSIS
    Promotes a managed solution from dev to a target environment, over a
    hand-edited component, and grades what actually landed.

    .DESCRIPTION
    The drill performs the promotion and records the evidence. It decides
    nothing: every classification is delegated to the SolutionLayers module,
    which makes no call to Dataverse and is covered by unit tests, so the
    judgement can be audited without an environment.

    Two passes, the same promotion each time:

      default    OverwriteUnmanagedCustomizations = false  (what every import does)
      overwrite  OverwriteUnmanagedCustomizations = true   (the documented fix)

    In both passes the import reports success and the target's solution version
    advances. Only the component value differs, which is the finding: the two
    signals a pipeline would check both say the deployment worked.

    A real promotion, not a simulated one. Dataverse refuses a hand-built
    managed solution -- "import again using the XML file that was generated
    when you exported the solution" -- so the solution is built unmanaged in
    dev, exported as managed, and imported into the target.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DevUrl,

    [Parameter(Mandatory)]
    [string] $TargetUrl,

    [Parameter()]
    [string] $MatrixPath = (Join-Path -Path $PSScriptRoot -ChildPath '../layer-matrix.json'),

    [Parameter()]
    [string] $ReportPath = 'layer-report.json',

    [Parameter()]
    [string] $MarkdownPath = 'layer-report.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Write-Information is the house style for progress in this series and is
# silent by default -- a run reporting nothing would look like a run doing
# nothing.
$InformationPreference = 'Continue'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../module/SolutionLayers/SolutionLayers.psm1') -Force

$matrix = Get-LayerMatrix -Path $MatrixPath
$solutionName = $matrix.component.solutionUniqueName
$publisherName = $matrix.component.publisherUniqueName
$webResource = $matrix.component.webResourceName

$DevUrl = $DevUrl.TrimEnd('/')
$TargetUrl = $TargetUrl.TrimEnd('/')

# ------------------------------------------------------------------- access

# One token per environment, fetched up front.
#
# Not az rest: on Windows, `az rest --method patch` through az.cmd fails with
# "--headers was unexpected at this time", a cmd.exe parsing artifact that has
# nothing to do with the request. Invoke-RestMethod also lets a non-2xx be
# handled as data rather than an exception, which matters because "the import
# succeeded" is a thing this drill has to record rather than assume.
# Tokens come from the environment first, and are only fetched with the Azure
# CLI when they are not supplied.
#
# Environment first because the CLI cannot always be asked. On Windows the
# CLI's MSAL cache is DPAPI-encrypted against the Windows user, so a Linux
# container with ~/.azure mounted can read azureProfile.json but cannot decrypt
# a token: `az account show` succeeds and `az account get-access-token` fails
# with "does not exist in MSAL token cache", which is a confusing pair to debug.
# It also lets CI supply a token from a federated credential without the CLI in
# the picture at all.
#
# Environment variables rather than parameters, so a token never lands in a
# process argument list where anything else on the machine can read it.
$script:Tokens = @{}
$supplied = @{ $DevUrl = $env:DATAVERSE_DEV_TOKEN; $TargetUrl = $env:DATAVERSE_TARGET_TOKEN }

foreach ($url in $DevUrl, $TargetUrl) {
    $token = $supplied[$url]

    if ([string]::IsNullOrWhiteSpace($token)) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw ("No token for $url. Set DATAVERSE_DEV_TOKEN and DATAVERSE_TARGET_TOKEN, " +
                'or make the Azure CLI available so the drill can fetch them itself.')
        }
        # Errors are captured rather than suppressed. The first version sent
        # them to $null and the drill reported "could not get a token" without
        # saying why, which cost a debugging round trip for a message the CLI
        # had already produced.
        $output = & az account get-access-token --resource "$url/" --query accessToken -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) {
            $token = ($output | Select-Object -Last 1)
        } else {
            throw "Could not get a Dataverse token for $url. The Azure CLI said: $($output -join ' ')"
        }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "The token for $url is empty. Refusing to run: every call would return 401 and every guard would grade Unknown."
    }
    $script:Tokens[$url] = $token.Trim()
}

function Invoke-Dataverse {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [Parameter()][object] $Body,
        [Parameter()][hashtable] $ExtraHeaders = @{}
    )

    $headers = @{
        Authorization      = "Bearer $($script:Tokens[$Environment])"
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Accept             = 'application/json'
    }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }

    $params = @{
        Method             = $Method
        Uri                = "$Environment/api/data/v9.2/$Path"
        Headers            = $headers
        SkipHttpErrorCheck = $true
        StatusCodeVariable = 'status'
    }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json'
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    $response = Invoke-RestMethod @params
    return [pscustomobject]@{
        StatusCode = $status
        Body       = $response
        Ok         = ($status -ge 200 -and $status -lt 300)
    }
}

function Get-ComponentValue {
    <#
        .SYNOPSIS
        Reads the web resource content an environment currently serves.

        .DESCRIPTION
        Returns $null when it cannot be read, and never an empty string for
        that case. An empty web resource is a value a solution can legitimately
        ship, so "absent" and "empty" have to stay different -- the module
        grades a null as Unknown and an empty string as a real comparison.
    #>
    # Both types are declared on purpose. [object] is the honest contract --
    # this returns $null when the value could not be read -- but the analyser
    # only checks the types actually returned, and a bare [object] makes it
    # report the undeclared [string]. Listing both keeps the scan clean without
    # claiming the function always returns a value.
    [CmdletBinding()]
    [OutputType([object], [string])]
    param([Parameter(Mandatory)][string] $Environment)

    $result = Invoke-Dataverse -Environment $Environment -Method Get `
        -Path "webresourceset?`$select=content&`$filter=name eq '$webResource'"
    if (-not $result.Ok) { return $null }

    $rows = @($result.Body.value)
    if (-not $rows.Count) { return $null }
    if ([string]::IsNullOrEmpty($rows[0].content)) { return '' }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rows[0].content))
}

function Get-SolutionVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Environment)

    $result = Invoke-Dataverse -Environment $Environment -Method Get `
        -Path "solutions?`$select=version&`$filter=uniquename eq '$solutionName'"
    if (-not $result.Ok) { return '' }
    $rows = @($result.Body.value)
    if (-not $rows.Count) { return '' }
    return [string]$rows[0].version
}

function Initialize-DevSolution {
    <#
        .SYNOPSIS
        Ensures the publisher and solution exist in dev.

        .DESCRIPTION
        Idempotent, and here so the lab runs against a pair of empty
        environments rather than needing somebody to have clicked through the
        maker portal first. The publisher carries the customisation prefix,
        which is part of a component's name once it ships, so it cannot be left
        to whatever default the environment happens to have.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($DevUrl, 'ensure publisher and solution')) { return }

    $pub = Invoke-Dataverse -Environment $DevUrl -Method Get `
        -Path "publishers?`$select=publisherid&`$filter=uniquename eq '$publisherName'"
    $pubRows = @($pub.Body.value)
    if (-not $pubRows.Count) {
        $created = Invoke-Dataverse -Environment $DevUrl -Method Post -Path 'publishers' -Body @{
            uniquename = $publisherName; friendlyname = 'Guard Publisher'
            customizationprefix = 'guard'; customizationoptionvalueprefix = 10000
        }
        if (-not $created.Ok) { throw "Could not create the publisher: HTTP $($created.StatusCode)" }
        $pub = Invoke-Dataverse -Environment $DevUrl -Method Get `
            -Path "publishers?`$select=publisherid&`$filter=uniquename eq '$publisherName'"
        $pubRows = @($pub.Body.value)
        Write-Information "  created publisher '$publisherName'"
    }

    $sol = Invoke-Dataverse -Environment $DevUrl -Method Get `
        -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$solutionName'"
    if (-not @($sol.Body.value).Count) {
        $created = Invoke-Dataverse -Environment $DevUrl -Method Post -Path 'solutions' -Body @{
            uniquename = $solutionName; friendlyname = 'Guard Layer'; version = '1.0.0.0'
            'publisherid@odata.bind' = "/publishers($($pubRows[0].publisherid))"
        }
        if (-not $created.Ok) { throw "Could not create the solution: HTTP $($created.StatusCode)" }
        Write-Information "  created solution '$solutionName'"
    }
}

function Set-DevComponent {
    <#
        .SYNOPSIS
        Puts a value into the dev solution and bumps its version.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Version
    )
    if (-not $PSCmdlet.ShouldProcess($DevUrl, "ship '$Value' as $Version")) { return }

    $wr = Invoke-Dataverse -Environment $DevUrl -Method Get `
        -Path "webresourceset?`$select=webresourceid&`$filter=name eq '$webResource'"
    $rows = @($wr.Body.value)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))

    if ($rows.Count) {
        $patch = Invoke-Dataverse -Environment $DevUrl -Method Patch `
            -Path "webresourceset($($rows[0].webresourceid))" -Body @{ content = $encoded }
        if (-not $patch.Ok) { throw "Could not update the dev web resource: HTTP $($patch.StatusCode)" }
    } else {
        # The header is what puts the component inside the solution. Without it
        # the web resource is created in the default solution and the export
        # contains nothing, so the import would land an empty solution and
        # every guard would grade Unknown.
        $create = Invoke-Dataverse -Environment $DevUrl -Method Post -Path 'webresourceset' `
            -Body @{ name = $webResource; displayname = $webResource; webresourcetype = 4; content = $encoded } `
            -ExtraHeaders @{ 'MSCRM.SolutionUniqueName' = $solutionName }
        if (-not $create.Ok) { throw "Could not create the dev web resource: HTTP $($create.StatusCode) $($create.Body | ConvertTo-Json -Compress -Depth 4)" }
    }

    $sol = Invoke-Dataverse -Environment $DevUrl -Method Get `
        -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$solutionName'"
    $solRows = @($sol.Body.value)
    if (-not $solRows.Count) { throw "Solution '$solutionName' does not exist in dev." }
    $bump = Invoke-Dataverse -Environment $DevUrl -Method Patch `
        -Path "solutions($($solRows[0].solutionid))" -Body @{ version = $Version }
    if (-not $bump.Ok) { throw "Could not bump the dev solution version: HTTP $($bump.StatusCode)" }

    $publish = Invoke-Dataverse -Environment $DevUrl -Method Post -Path 'PublishAllXml' -Body @{}
    if (-not $publish.Ok) { throw "PublishAllXml failed in dev: HTTP $($publish.StatusCode)" }
}

function Export-ManagedSolution {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $export = Invoke-Dataverse -Environment $DevUrl -Method Post -Path 'ExportSolution' `
        -Body @{ SolutionName = $solutionName; Managed = $true }
    if (-not $export.Ok) { throw "ExportSolution failed: HTTP $($export.StatusCode)" }
    if ([string]::IsNullOrWhiteSpace($export.Body.ExportSolutionFile)) {
        throw 'ExportSolution returned no file. Importing nothing would grade every guard Unknown rather than failing here.'
    }
    return $export.Body.ExportSolutionFile
}

function Import-ManagedSolution {
    <#
        .SYNOPSIS
        Imports the managed solution into the target and reports whether the
        call succeeded -- separately from whether anything changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Base64Zip,
        [Parameter(Mandatory)][bool] $Overwrite
    )
    if (-not $PSCmdlet.ShouldProcess($TargetUrl, "import (overwrite=$Overwrite)")) { return }

    # ImportJobId is required. Omitting it returns a payload error naming it,
    # which reads like a malformed request rather than a missing field.
    $jobId = [guid]::NewGuid().ToString()
    $import = Invoke-Dataverse -Environment $TargetUrl -Method Post -Path 'ImportSolution' -Body @{
        CustomizationFile                = $Base64Zip
        ImportJobId                      = $jobId
        OverwriteUnmanagedCustomizations = $Overwrite
        PublishWorkflows                 = $false
    }

    # Publish afterwards so the read reflects the import rather than a cache.
    if ($import.Ok) { $null = Invoke-Dataverse -Environment $TargetUrl -Method Post -Path 'PublishAllXml' -Body @{} }

    return [pscustomobject]@{
        JobId      = $jobId
        StatusCode = $import.StatusCode
        Succeeded  = $import.Ok
    }
}

function Get-ComponentLayerCount {
    <#
        .SYNOPSIS
        How many layer rows Dataverse reports for the component.

        .DESCRIPTION
        Returns $null when the query itself fails, which is different from zero.
        The matrix declares that this comes back empty, and that assertion is
        marked uncertain on purpose -- an unreadable table must not be counted
        as evidence for it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()

    $result = Invoke-Dataverse -Environment $TargetUrl -Method Get `
        -Path "msdyn_componentlayers?`$select=msdyn_name,msdyn_solutionname&`$filter=msdyn_name eq '$webResource'"
    if (-not $result.Ok) {
        Write-Information "  (layers query returned HTTP $($result.StatusCode))"
        return $null
    }
    return @($result.Body.value).Count
}

# ------------------------------------------------------------------- the drill

Write-Information "== dev scaffolding"
Initialize-DevSolution

$guardResults = @()
$observations = @{}

foreach ($pass in 'default', 'overwrite') {
    $overwrite = [bool]$matrix.passes.$pass.overwriteUnmanagedCustomizations
    Write-Information "`n== $pass pass (OverwriteUnmanagedCustomizations = $overwrite)"

    # --- baseline: an import with nothing local in the way.
    #
    # The target's copy is deleted first so each pass starts from the same
    # place. Without this the second pass would inherit whatever the first left
    # behind, and a guard could pass for the wrong reason.
    Write-Information '  resetting the target'
    $existing = Invoke-Dataverse -Environment $TargetUrl -Method Get `
        -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$solutionName'"
    foreach ($row in @($existing.Body.value)) {
        $null = Invoke-Dataverse -Environment $TargetUrl -Method Delete -Path "solutions($($row.solutionid))"
    }

    $baselineValue = "baseline-$pass-$(Get-Random)"
    Set-DevComponent -Value $baselineValue -Version '1.0.0.1'
    $zip = Export-ManagedSolution
    $beforeBaseline = Get-ComponentValue -Environment $TargetUrl
    $baselineImport = Import-ManagedSolution -Base64Zip $zip -Overwrite $overwrite
    $afterBaseline = Get-ComponentValue -Environment $TargetUrl

    $verdict = Resolve-ImportOutcome -Shipped $baselineValue -Before $beforeBaseline -After $afterBaseline `
        -ImportFailed (-not $baselineImport.Succeeded)
    $guard = $matrix.guards | Where-Object { $_.id -eq 'baseline-import-applies' }
    $guardResults += Test-GuardExpectation -Guard $guard -Pass $pass -Observed $verdict.Outcome -Reason $verdict.Reason
    Write-Information ("  {0,-34} {1}" -f 'baseline-import-applies', $verdict.Outcome)

    # --- the finding: hand-edit the managed component, then import over it.
    Write-Information '  hand-editing the managed component in the target'
    $handEdit = "hand-edited-$(Get-Random)"
    $wr = Invoke-Dataverse -Environment $TargetUrl -Method Get `
        -Path "webresourceset?`$select=webresourceid&`$filter=name eq '$webResource'"
    $wrRows = @($wr.Body.value)
    if (-not $wrRows.Count) { throw 'The web resource is not in the target after the baseline import, so there is nothing to hand-edit.' }
    $edit = Invoke-Dataverse -Environment $TargetUrl -Method Patch -Path "webresourceset($($wrRows[0].webresourceid))" `
        -Body @{ content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($handEdit)) }
    if (-not $edit.Ok) { throw "Could not hand-edit the target component: HTTP $($edit.StatusCode)" }
    $null = Invoke-Dataverse -Environment $TargetUrl -Method Post -Path 'PublishAllXml' -Body @{}

    $confirmed = Get-ComponentValue -Environment $TargetUrl
    if ($confirmed -ne $handEdit) {
        # Without a divergence there is no unmanaged layer, and the guard below
        # would be measuring an ordinary import.
        throw "The hand edit did not take: the target serves '$confirmed' rather than '$handEdit'. There is no unmanaged layer to import over."
    }

    $shippedValue = "shipped-$pass-$(Get-Random)"
    Set-DevComponent -Value $shippedValue -Version '1.0.0.2'
    $zip = Export-ManagedSolution

    $versionBefore = Get-SolutionVersion -Environment $TargetUrl
    $layersBefore = Get-ComponentLayerCount
    $import = Import-ManagedSolution -Base64Zip $zip -Overwrite $overwrite
    $versionAfter = Get-SolutionVersion -Environment $TargetUrl
    $afterValue = Get-ComponentValue -Environment $TargetUrl

    $verdict = Resolve-ImportOutcome -Shipped $shippedValue -Before $handEdit -After $afterValue `
        -ImportFailed (-not $import.Succeeded)
    $guard = $matrix.guards | Where-Object { $_.id -eq 'import-over-unmanaged-layer' }
    $guardResults += Test-GuardExpectation -Guard $guard -Pass $pass -Observed $verdict.Outcome -Reason $verdict.Reason
    Write-Information ("  {0,-34} {1}" -f 'import-over-unmanaged-layer', $verdict.Outcome)

    $versionMove = Compare-SolutionVersion -Before $versionBefore -After $versionAfter
    Write-Information "  import reported success: $($import.Succeeded) (HTTP $($import.StatusCode))"
    Write-Information "  $($versionMove.Reason)"
    Write-Information "  layer rows for the component: $(if ($null -eq $layersBefore) { 'unreadable' } else { $layersBefore })"

    $observations[$pass] = [pscustomobject]@{
        ImportSucceeded = $import.Succeeded
        VersionAdvanced = if ($versionMove.Known) { $versionMove.Advanced } else { $null }
        LayerRows       = $layersBefore
        Shipped         = $shippedValue
        HandEdit        = $handEdit
        Served          = $afterValue
    }
}

# ------------------------------------------------------------------ assertions

Write-Information "`n== assertions about the observable signals"

$assertionResults = @()
foreach ($assertion in $matrix.assertions) {
    # Each assertion must hold in BOTH passes. An aggregate that were true in
    # one pass only would be reported as true, which for "the import always
    # reports success" is exactly the wrong reading.
    $observed = switch ($assertion.id) {
        'import-reports-success' {
            $vals = @($observations.Values | ForEach-Object { $_.ImportSucceeded })
            if ($vals -contains $null) { $null } else { -not ($vals -contains $false) }
        }
        'solution-version-advances' {
            $vals = @($observations.Values | ForEach-Object { $_.VersionAdvanced })
            if ($vals -contains $null) { $null } else { -not ($vals -contains $false) }
        }
        'component-layers-table-is-empty' {
            $vals = @($observations.Values | ForEach-Object { $_.LayerRows })
            if ($vals -contains $null) { $null } else { -not ($vals | Where-Object { $_ -gt 0 }) }
        }
        default { $null }
    }

    $reason = if ($null -eq $observed) { 'Could not be measured in both passes.' } else { "Observed $observed in both passes." }
    $assertionResults += Test-AssertionExpectation -Assertion $assertion -Observed $observed -Reason $reason
    Write-Information ("  {0,-34} {1}" -f $assertion.id, $(if ($null -eq $observed) { 'unmeasured' } else { $observed }))
}

# ------------------------------------------------------------------- reporting

$report = Get-LayerReport -GuardResult $guardResults -AssertionResult $assertionResults

$payload = [pscustomobject]@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    dev          = $DevUrl
    target       = $TargetUrl
    observations = $observations
    total        = $report.Total
    passed       = $report.Passed
    failed       = $report.Failed
    inconclusive = $report.Inconclusive
    ok           = $report.Ok
    guards       = $report.GuardResults
    assertions   = $report.AssertionResults
}
[System.IO.File]::WriteAllText($ReportPath, ($payload | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

$lines = @(
    '# The import said success'
    ''
    "$($report.Passed)/$($report.Total) behaved as declared. $($report.Failed) failed, $($report.Inconclusive) inconclusive."
    ''
    '| Guard | Pass | Expected | Observed | |'
    '|---|---|---|---|---|'
)
foreach ($r in $report.GuardResults) {
    $mark = if ($r.Inconclusive) { 'inconclusive' } elseif ($r.Passed) { 'as declared' } else { 'FAILED' }
    $lines += "| ``$($r.Id)`` | $($r.Pass) | $($r.Expected) | $($r.Observed) | $mark |"
}
$lines += @('', '| Signal | Expected | Observed | |', '|---|---|---|---|')
foreach ($r in $report.AssertionResults) {
    $mark = if ($r.Inconclusive) { 'unmeasured' } elseif ($r.Passed) { 'as declared' } else { 'FAILED' }
    $lines += "| ``$($r.Id)`` | $($r.Expected) | $($r.Observed) | $mark |"
}
[System.IO.File]::WriteAllText($MarkdownPath, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Information ''
Write-Information "$($report.Passed)/$($report.Total) as declared; $($report.Failed) failed; $($report.Inconclusive) inconclusive."
foreach ($r in @($report.GuardResults + $report.AssertionResults | Where-Object { -not $_.Passed })) {
    Write-Information "FAILED  $($r.Id): expected $($r.Expected), observed $($r.Observed). $($r.Reason)"
}

if (-not $report.Ok) {
    throw "The drill did not hold: $($report.Failed) of $($report.Total) did not behave as declared."
}
Write-Information 'Everything behaved as declared.'
