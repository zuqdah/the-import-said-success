#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Every judgement the drill makes is decided here, against fixtures, with no
    Dataverse environment in reach.

    The tests that matter most assert a FAILURE: that an unread value is not a
    match, that a successful import is not evidence of anything, that an
    unmeasured assertion is not false, and that an empty result set is not a
    pass.
#>

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../module/SolutionLayers/SolutionLayers.psm1') -Force -ErrorAction Stop
    $script:MatrixPath = Join-Path -Path $PSScriptRoot -ChildPath '../layer-matrix.json'

    # A scriptblock in script scope, not a function. Functions declared in a
    # Describe block -- or at file scope -- are defined during Pester's
    # discovery phase and are gone by the time the It blocks run, which
    # surfaces as CommandNotFoundException and looks nothing like a scoping
    # problem.
    $script:WriteMatrix = {
        param([string] $Path, [string] $Json)
        [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding($false)))
    }
}

Describe 'Get-LayerMatrix' {

    It 'loads the real matrix shipped with the lab' {
        @((Get-LayerMatrix -Path $script:MatrixPath).guards).Count | Should -BeGreaterThan 0
    }

    It 'requires every guard and assertion to say why it exists' {
        $matrix = Get-LayerMatrix -Path $script:MatrixPath
        foreach ($g in $matrix.guards) { $g.why | Should -Not -BeNullOrEmpty -Because "guard '$($g.id)' must justify itself" }
        foreach ($a in $matrix.assertions) { $a.why | Should -Not -BeNullOrEmpty -Because "assertion '$($a.id)' must justify itself" }
    }

    It 'ships a matrix where the remediation changes an outcome' {
        $diverging = @((Get-LayerMatrix -Path $script:MatrixPath).guards | Where-Object { $_.expectDefault -ne $_.expectOverwrite })
        $diverging.Count | Should -BeGreaterThan 0 -Because 'otherwise the second pass proves no boundary'
    }

    It 'ships a matrix containing the Suppressed case this lab exists to catch' {
        @((Get-LayerMatrix -Path $script:MatrixPath).guards | Where-Object { $_.expectDefault -eq 'Suppressed' }).Count |
            Should -BeGreaterThan 0
    }

    Context 'refusing an incoherent matrix' {

        BeforeEach { $script:Temp = Join-Path ([IO.Path]::GetTempPath()) "layer-matrix-$([guid]::NewGuid()).json" }
        AfterEach { if (Test-Path -LiteralPath $script:Temp) { Remove-Item -LiteralPath $script:Temp -Force } }

        It 'refuses a matrix with no guards' {
            & $script:WriteMatrix $script:Temp '{ "guards": [], "assertions": [] }'
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*no guards*'
        }

        It 'refuses a guard that expects Unknown' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [ { "id":"a","title":"t","expectDefault":"Unknown","expectOverwrite":"Applied","severity":"Baseline","why":"w" } ],
  "assertions": [ { "id":"x","expect":true,"severity":"Critical","why":"w" } ] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage "*expects 'Unknown'*"
        }

        It 'refuses duplicate guard ids' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [
    { "id":"a","title":"t","expectDefault":"Applied","expectOverwrite":"Applied","severity":"Baseline","why":"w" },
    { "id":"a","title":"t","expectDefault":"Suppressed","expectOverwrite":"Applied","severity":"Critical","why":"w" } ],
  "assertions": [ { "id":"x","expect":true,"severity":"Critical","why":"w" } ] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*more than once*'
        }

        It 'refuses a matrix where no import is expected to land' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [ { "id":"a","title":"t","expectDefault":"Suppressed","expectOverwrite":"Applied","severity":"Critical","why":"w" } ],
  "assertions": [ { "id":"x","expect":true,"severity":"Critical","why":"w" } ] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*pass the finding for free*'
        }

        It 'refuses a matrix where nothing is expected to be suppressed' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [ { "id":"a","title":"t","expectDefault":"Applied","expectOverwrite":"Applied","severity":"Baseline","why":"w" } ],
  "assertions": [ { "id":"x","expect":true,"severity":"Critical","why":"w" } ] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*failure this lab exists to detect*'
        }

        It 'refuses a matrix with no diverging guard' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [
    { "id":"a","title":"t","expectDefault":"Applied","expectOverwrite":"Applied","severity":"Baseline","why":"w" },
    { "id":"b","title":"t","expectDefault":"Suppressed","expectOverwrite":"Suppressed","severity":"Critical","why":"w" } ],
  "assertions": [ { "id":"x","expect":true,"severity":"Critical","why":"w" } ] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*no remediation boundary*'
        }

        It 'refuses a matrix with no assertions, because half the point is undetectability' {
            & $script:WriteMatrix $script:Temp @'
{ "guards": [
    { "id":"a","title":"t","expectDefault":"Applied","expectOverwrite":"Applied","severity":"Baseline","why":"w" },
    { "id":"b","title":"t","expectDefault":"Suppressed","expectOverwrite":"Applied","severity":"Critical","why":"w" } ],
  "assertions": [] }
'@
            { Get-LayerMatrix -Path $script:Temp } | Should -Throw -ExpectedMessage '*only half its point*'
        }
    }
}

Describe 'Resolve-ImportOutcome' {

    It 'reports Applied when the target serves what the solution shipped' {
        (Resolve-ImportOutcome -Shipped 'v2' -Before 'v1' -After 'v2').Outcome | Should -Be 'Applied'
    }

    # The finding this lab exists for.
    It 'reports Suppressed when the target still serves the previous value' {
        $r = Resolve-ImportOutcome -Shipped 'v2' -Before 'hand-edited' -After 'hand-edited'
        $r.Outcome | Should -Be 'Suppressed'
        $r.Reason | Should -BeLike '*did not move*'
    }

    It 'reports Failed when the import itself failed, which is not the finding' {
        (Resolve-ImportOutcome -Shipped 'v2' -Before 'v1' -After 'v1' -ImportFailed $true).Outcome | Should -Be 'Failed'
    }

    # A successful import is deliberately not an input. If it were, the function
    # could not see the case where success and no change coexist.
    It 'does not take the import result as evidence that anything applied' {
        (Resolve-ImportOutcome -Shipped 'v2' -Before 'hand-edited' -After 'hand-edited' -ImportFailed $false).Outcome |
            Should -Be 'Suppressed'
    }

    It 'does NOT treat an unread target value as a match' {
        $r = Resolve-ImportOutcome -Shipped 'v2' -Before 'v1' -After $null
        $r.Outcome | Should -Be 'Unknown'
        $r.Outcome | Should -Not -Be 'Applied'
        $r.Reason | Should -BeLike '*must not be graded as having landed*'
    }

    It 'does NOT treat an unread shipped value as a match' {
        (Resolve-ImportOutcome -Shipped $null -Before 'v1' -After 'v1').Outcome | Should -Be 'Unknown'
    }

    It 'reports Unknown when the value is neither shipped nor previous' {
        $r = Resolve-ImportOutcome -Shipped 'v2' -Before 'v1' -After 'something-else'
        $r.Outcome | Should -Be 'Unknown'
        $r.Reason | Should -BeLike '*outside this drill*'
    }
}

Describe 'Compare-SolutionVersion' {

    It 'sees a version advance' {
        $r = Compare-SolutionVersion -Before '1.0.0.1' -After '1.0.0.2'
        $r.Advanced | Should -BeTrue
        $r.Known | Should -BeTrue
    }

    It 'sees a version that did not move' {
        (Compare-SolutionVersion -Before '1.0.0.2' -After '1.0.0.2').Advanced | Should -BeFalse
    }

    # A lab whose finding turns on a version number should not be wrong about
    # which version is newer.
    It 'compares as versions, not as strings' {
        (Compare-SolutionVersion -Before '1.0.0.9' -After '1.0.0.10').Advanced | Should -BeTrue
    }

    It 'reports unknown rather than guessing on an unparseable version' {
        $r = Compare-SolutionVersion -Before 'not-a-version' -After '1.0.0.2'
        $r.Known | Should -BeFalse
        $r.Advanced | Should -BeFalse
    }
}

Describe 'Test-GuardExpectation' {

    BeforeAll {
        $script:Guard = [pscustomobject]@{
            id = 'import-over-unmanaged-layer'; title = 't'
            expectDefault = 'Suppressed'; expectOverwrite = 'Applied'
            severity = 'Critical'; why = 'because'
        }
    }

    It 'grades the two passes against different expectations' {
        (Test-GuardExpectation -Guard $script:Guard -Pass 'default' -Observed 'Suppressed').Passed | Should -BeTrue
        (Test-GuardExpectation -Guard $script:Guard -Pass 'overwrite' -Observed 'Applied').Passed | Should -BeTrue
    }

    It 'fails when the remediation pass did not land' {
        (Test-GuardExpectation -Guard $script:Guard -Pass 'overwrite' -Observed 'Suppressed').Passed | Should -BeFalse
    }

    It 'fails an Unknown observation even where it would otherwise have matched' {
        $g = [pscustomobject]@{ id='x'; title='t'; expectDefault='Applied'; expectOverwrite='Applied'; severity='Baseline'; why='w' }
        $r = Test-GuardExpectation -Guard $g -Pass 'default' -Observed 'Unknown'
        $r.Passed | Should -BeFalse
        $r.Inconclusive | Should -BeTrue
    }
}

Describe 'Test-AssertionExpectation' {

    BeforeAll {
        $script:Assertion = [pscustomobject]@{ id = 'solution-version-advances'; expect = $true; severity = 'Critical'; why = 'because' }
    }

    It 'passes when the signal behaved as declared' {
        (Test-AssertionExpectation -Assertion $script:Assertion -Observed $true).Passed | Should -BeTrue
    }

    It 'fails when the signal did not' {
        (Test-AssertionExpectation -Assertion $script:Assertion -Observed $false).Passed | Should -BeFalse
    }

    # Null is not false. An assertion nobody could measure must be visible as
    # unmeasured rather than quietly counted as evidence either way.
    It 'does NOT treat an unmeasured assertion as false' {
        $r = Test-AssertionExpectation -Assertion $script:Assertion -Observed $null
        $r.Passed | Should -BeFalse
        $r.Inconclusive | Should -BeTrue
    }
}

Describe 'Get-LayerReport' {

    It 'reports ok when every guard and assertion behaved' {
        $g = @([pscustomobject]@{ Passed=$true; Inconclusive=$false; Severity='Critical' })
        $a = @([pscustomobject]@{ Passed=$true; Inconclusive=$false; Severity='Critical' })
        (Get-LayerReport -GuardResult $g -AssertionResult $a).Ok | Should -BeTrue
    }

    It 'is not ok when an assertion failed, even with every guard passing' {
        $g = @([pscustomobject]@{ Passed=$true; Inconclusive=$false; Severity='Critical' })
        $a = @([pscustomobject]@{ Passed=$false; Inconclusive=$false; Severity='Critical' })
        (Get-LayerReport -GuardResult $g -AssertionResult $a).Ok | Should -BeFalse
    }

    It 'is not ok when anything was inconclusive' {
        $g = @([pscustomobject]@{ Passed=$false; Inconclusive=$true; Severity='Critical' })
        (Get-LayerReport -GuardResult $g).Ok | Should -BeFalse
    }

    It 'is not ok for an empty guard set' {
        (Get-LayerReport -GuardResult @()).Ok | Should -BeFalse
    }
}
