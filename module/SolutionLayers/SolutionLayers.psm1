#Requires -Version 7.0

<#
    SolutionLayers

    The judgement half of the lab, with no call to Dataverse, so every decision
    about what an observation means can be tested without an environment.

    It exists because of one distinction: a solution import reporting success
    is not evidence that anything changed.

    An unmanaged layer -- created by editing a managed component directly in
    the target, which is all it takes -- makes every later import of that
    solution leave the component alone. The import returns success. The
    solution version advances. The component serves the hand edit. So the two
    signals a pipeline would check, the import result and the deployed version,
    both say yes while the thing being deployed is stale.

    The only honest measurement compares what the solution SHIPPED against what
    the target now SERVES, which is why Resolve-ImportOutcome takes both and
    infers neither from the other.
#>

Set-StrictMode -Version Latest

$script:KnownOutcomes = @('Applied', 'Suppressed', 'Failed', 'Unknown')

function Get-KnownImportOutcome {
    <#
        .SYNOPSIS
        The outcomes a drill is allowed to report.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]$script:KnownOutcomes
}

function Get-LayerMatrix {
    <#
        .SYNOPSIS
        Loads layer-matrix.json and refuses to return an incoherent one.

        .DESCRIPTION
        A matrix that declares nothing testable makes the drill unfalsifiable
        while its report still looks rigorous. Everything that would make the
        results meaningless throws here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Layer matrix not found at '$Path'."
    }

    # Not Get-Content -Raw: it returns a string carrying ETS note properties
    # whose object graph makes ConvertFrom-Json hang.
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Layer matrix at '$Path' is empty."
    }

    $matrix = $text | ConvertFrom-Json

    $guards = @($matrix.guards)
    if (-not $guards.Count) {
        throw 'The layer matrix declares no guards.'
    }

    $seen = @{}
    foreach ($guard in $guards) {
        foreach ($field in 'id', 'title', 'expectDefault', 'expectOverwrite', 'severity', 'why') {
            if (-not ($guard.PSObject.Properties.Name -contains $field) -or
                [string]::IsNullOrWhiteSpace([string]$guard.$field)) {
                throw "Guard '$($guard.id)' is missing '$field'. Every guard must state what it expects and why."
            }
        }

        if ($seen.ContainsKey($guard.id)) {
            throw "Guard id '$($guard.id)' is declared more than once."
        }
        $seen[$guard.id] = $true

        foreach ($field in 'expectDefault', 'expectOverwrite') {
            if ($guard.$field -notin $script:KnownOutcomes) {
                throw "Guard '$($guard.id)' expects '$($guard.$field)' for $field, which is not a known outcome."
            }
            if ($guard.$field -eq 'Unknown') {
                throw "Guard '$($guard.id)' expects 'Unknown', which no guard may expect."
            }
        }
    }

    # The drill has to observe an import that lands and an import that does
    # not. Without the first it never shows that applying is achievable, and a
    # broken value read would report Suppressed for everything and pass the
    # finding for free. Without the second there is no finding.
    if (-not @($guards | Where-Object { $_.expectDefault -eq 'Applied' }).Count) {
        throw 'No guard expects an import to land in the default pass, so a drill that reported Suppressed for everything would pass the finding for free.'
    }
    if (-not @($guards | Where-Object { $_.expectDefault -eq 'Suppressed' }).Count) {
        throw 'No guard expects an import to be suppressed. That is the failure this lab exists to detect, and without one declared, a drill that could not detect it would still pass.'
    }

    # The two-pass design only proves something if the remediation changes an
    # outcome. With no divergence the second pass is an expensive way to get
    # the same answer twice, and the report would claim a boundary it never
    # crossed.
    if (-not @($guards | Where-Object { $_.expectDefault -ne $_.expectOverwrite }).Count) {
        throw 'No guard expects a different outcome with OverwriteUnmanagedCustomizations set, so the second pass demonstrates no remediation boundary.'
    }

    $assertions = @($matrix.assertions)
    if (-not $assertions.Count) {
        throw 'The layer matrix declares no assertions. The guards show that the change did not land; the assertions are what show it is undetectable, and without them the lab is only half its point.'
    }
    foreach ($assertion in $assertions) {
        foreach ($field in 'id', 'severity', 'why') {
            if (-not ($assertion.PSObject.Properties.Name -contains $field) -or
                [string]::IsNullOrWhiteSpace([string]$assertion.$field)) {
                throw "Assertion '$($assertion.id)' is missing '$field'."
            }
        }
        if (-not ($assertion.PSObject.Properties.Name -contains 'expect')) {
            throw "Assertion '$($assertion.id)' declares no expected value."
        }
    }

    return $matrix
}

function Resolve-ImportOutcome {
    <#
        .SYNOPSIS
        Decides whether an import landed, by comparing what it shipped against
        what the target now serves.

        .DESCRIPTION
        Three inputs, none inferred from the others:

          Shipped  - the value inside the solution that was imported.
          Before   - what the target served before the import.
          After    - what the target serves now.

        The import's own success is deliberately NOT one of them. A successful
        import that changed nothing is the entire subject of this lab, so
        taking the import result as evidence of application would make the
        function incapable of seeing it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # [object], not [string], and that is load-bearing.
        #
        # A [string] parameter coerces $null to the empty string, so the null
        # checks below became dead code and "could not read the value" was
        # graded as "the value is empty". Two tests caught it: an unread value
        # compared equal to another unread one and reported Suppressed.
        #
        # The distinction matters beyond the bug. An empty web resource is a
        # legitimate value a solution can ship, so '' and null have to stay
        # different things: one is a measurement, the other is its absence.
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Shipped,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Before,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $After,

        # Whether the import call itself failed. Only used to separate a real
        # error from the silent case: a failed import is not a finding, it is a
        # broken deployment somebody will already have noticed.
        [Parameter()]
        [bool] $ImportFailed = $false
    )

    if ($ImportFailed) {
        return [pscustomobject]@{
            Outcome = 'Failed'
            Reason  = 'The import itself failed, so nothing can be concluded about layering. A visible error is not what this lab is about.'
        }
    }

    # A missing reading is not a match. Treating an unread value as equal to
    # anything would turn every failed measurement into a pass.
    if ($null -eq $Shipped -or $null -eq $After) {
        $missing = @()
        if ($null -eq $Shipped) { $missing += 'the shipped value' }
        if ($null -eq $After) { $missing += 'the value the target serves' }
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = "Cannot compare: $($missing -join ' and ') could not be read. An unmeasured import must not be graded as having landed."
        }
    }

    # Compared as strings only after both are known to be non-null, so the
    # cast cannot reintroduce the coercion the parameter types now avoid.
    if ([string]$After -eq [string]$Shipped) {
        return [pscustomobject]@{
            Outcome = 'Applied'
            Reason  = "The target serves '$After', which is what the solution shipped."
        }
    }

    if ($null -ne $Before -and [string]$After -eq [string]$Before) {
        return [pscustomobject]@{
            Outcome = 'Suppressed'
            Reason  = "The solution shipped '$Shipped' and the target still serves '$Before', unchanged by the import. The import reported success and the component did not move."
        }
    }

    # Neither the shipped value nor the previous one. Something else changed
    # it, and guessing which would be worse than saying so.
    return [pscustomobject]@{
        Outcome = 'Unknown'
        Reason  = "The target serves '$After', which is neither the shipped value '$Shipped' nor the previous value '$Before'. Something outside this drill changed it."
    }
}

function Compare-SolutionVersion {
    <#
        .SYNOPSIS
        Reports whether a solution version moved forward.

        .DESCRIPTION
        Compared as versions rather than strings, because '1.0.0.10' sorts
        before '1.0.0.9' as text and a lab whose findings turn on a version
        number should not be wrong about which one is newer.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Before,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $After
    )

    $parsedBefore = $null
    $parsedAfter = $null
    $okBefore = [version]::TryParse($Before, [ref]$parsedBefore)
    $okAfter = [version]::TryParse($After, [ref]$parsedAfter)

    if (-not $okBefore -or -not $okAfter) {
        return [pscustomobject]@{
            Advanced = $false
            Known    = $false
            Reason   = "Could not parse '$Before' or '$After' as a version, so whether the solution moved forward is unknown."
        }
    }

    return [pscustomobject]@{
        Advanced = ($parsedAfter -gt $parsedBefore)
        Known    = $true
        Reason   = if ($parsedAfter -gt $parsedBefore) {
            "The target's solution version advanced from $Before to $After."
        } elseif ($parsedAfter -eq $parsedBefore) {
            "The target's solution version stayed at $Before."
        } else {
            "The target's solution version went backwards, from $Before to $After."
        }
    }
}

function Test-GuardExpectation {
    <#
        .SYNOPSIS
        Grades one observation against what the matrix declared for that pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Guard,

        [Parameter(Mandatory)]
        [ValidateSet('default', 'overwrite')]
        [string] $Pass,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Observed,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Reason = ''
    )

    $expected = if ($Pass -eq 'default') { $Guard.expectDefault } else { $Guard.expectOverwrite }

    # Stated separately from the comparison because it is the rule the module
    # exists to enforce: an unclassifiable observation fails even where the
    # expectation would otherwise have been met by accident.
    $inconclusive = $Observed -eq 'Unknown'
    $passed = (-not $inconclusive) -and ($Observed -eq $expected)

    return [pscustomobject]@{
        Id           = $Guard.id
        Title        = $Guard.title
        Severity     = $Guard.severity
        Pass         = $Pass
        Expected     = $expected
        Observed     = $Observed
        Passed       = $passed
        Inconclusive = $inconclusive
        Reason       = $Reason
        Why          = $Guard.why
    }
}

function Test-AssertionExpectation {
    <#
        .SYNOPSIS
        Grades one declared statement about the observable signals.

        .DESCRIPTION
        Separate from the guards because these are not import outcomes. They
        are the ways somebody would try to notice that a component went stale
        -- the import result, the deployed version, the layers table -- and
        each one is declared to show that it does not help.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Assertion,

        [Parameter(Mandatory)]
        [AllowNull()]
        [Nullable[bool]] $Observed,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Reason = ''
    )

    # Null is not false. An assertion nobody could measure has to be visible as
    # unmeasured, or it silently becomes evidence for whichever answer the
    # default happens to be.
    $inconclusive = $null -eq $Observed
    $passed = (-not $inconclusive) -and ($Observed -eq [bool]$Assertion.expect)

    return [pscustomobject]@{
        Id           = $Assertion.id
        Severity     = $Assertion.severity
        Expected     = [bool]$Assertion.expect
        Observed     = $Observed
        Passed       = $passed
        Inconclusive = $inconclusive
        Reason       = $Reason
        Why          = $Assertion.why
    }
}

function Get-LayerReport {
    <#
        .SYNOPSIS
        Summarises graded results and says whether the drill as a whole holds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $GuardResult,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]] $AssertionResult = @()
    )

    $guards = @($GuardResult)
    $assertions = @($AssertionResult)
    $all = $guards + $assertions

    $failed = @($all | Where-Object { -not $_.Passed })
    $inconclusive = @($all | Where-Object { $_.Inconclusive })

    # An empty result set is not a pass. A drill that graded nothing looks
    # identical to one where everything behaved.
    $ok = ($guards.Count -gt 0) -and ($failed.Count -eq 0)

    return [pscustomobject]@{
        Total            = $all.Count
        Passed           = @($all | Where-Object { $_.Passed }).Count
        Failed           = $failed.Count
        Inconclusive     = $inconclusive.Count
        Ok               = $ok
        GuardResults     = $guards
        AssertionResults = $assertions
    }
}

Export-ModuleMember -Function @(
    'Get-KnownImportOutcome'
    'Get-LayerMatrix'
    'Resolve-ImportOutcome'
    'Compare-SolutionVersion'
    'Test-GuardExpectation'
    'Test-AssertionExpectation'
    'Get-LayerReport'
)
