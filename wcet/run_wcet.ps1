<#
.SYNOPSIS
    Runs the sewcet WCET extraction or CSV comparison.
.DESCRIPTION
    - Pass -Elf (-e) to generate the static WCET CSV (and optionally -Compare/-cmp to compare).
    - Pass -Compare (-cmp) with two CSV files (without -Elf) to only run the comparison.
.EXAMPLE
    .\wcet\run_wcet.ps1 -Elf .\build\Debug\<project>.elf
    .\wcet\run_wcet.ps1 -e .\build\Debug\<project>.elf -o .\wcet\<wcet>.csv
    .\wcet\run_wcet.ps1 -cmp .\<measured>.csv .\wcet\<wcet>.csv
    .\wcet\run_wcet.ps1 -cmp .\<measured>.csv .\wcet\<wcet>.csv -o .\wcet\comparison.csv
#>
[CmdletBinding()]
param(
    [string]$Config,

    [Alias('e')]
    [string]$Elf,

    [Alias('o', 'Output')]
    [string]$Out,

    [Alias('cmp', 'c')]
    [string[]]$Compare,

    [ValidateSet('m0', 'm0plus', 'm23', 'm3', 'm4', 'm33', 'm7', 'trivial', 'generic')]
    [string]$Model,

    [switch]$WcetOnly,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

function Resolve-CallerPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

if ($ExtraArgs) {
    $remArgs = @()
    foreach ($arg in $ExtraArgs) {
        if (-not $Elf -and $arg -match '\.elf$') {
            $Elf = $arg
        } elseif ($Compare) {
            $Compare = @($Compare) + @($arg)
        } elseif (-not $Elf) {
            $Elf = $arg
        } else {
            $remArgs += $arg
        }
    }
    $ExtraArgs = $remArgs
}

if (-not $Elf -and (-not $Compare -or $Compare.Count -eq 0)) {
    throw "Specify -Elf <firmware.elf> to generate WCET, or -Compare <measured.csv> <wcet.csv> to compare two CSV files."
}

if ($Elf -and -not (Test-Path -LiteralPath $Elf)) {
    throw "ELF file not found: $Elf"
}

$resolvedCompare = @()
if ($Compare) {
    foreach ($csv in $Compare) {
        foreach ($part in ($csv -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) {
                $fullCsv = Resolve-CallerPath $trimmed
                if (-not (Test-Path -LiteralPath $fullCsv)) {
                    throw "Comparison CSV file not found: $trimmed"
                }
                $resolvedCompare += $fullCsv
            }
        }
    }
}

$configPath = if ($Config) { Resolve-CallerPath $Config } else { Join-Path $PSScriptRoot 'wcet_targets.json' }
$wcetOnlyFlag = ($WcetOnly.IsPresent -or ([bool]$Elf -and ($resolvedCompare.Count -eq 0)))

function Write-AnalysisRecord {
    if (-not $Elf) { return }
    $settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $csvPath = if ($Out) {
        Resolve-CallerPath $Out
    } else {
        $relativeOutput = if ($settings.output_csv) { $settings.output_csv } else { '1w.csv' }
        [System.IO.Path]::GetFullPath((Join-Path (Split-Path $configPath) $relativeOutput))
    }
    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "WCET runner succeeded but output is missing: $csvPath"
    }
    $rows = @(Import-Csv -LiteralPath $csvPath)
    if ($rows.Count -eq 0) { throw "WCET runner produced no function estimates: $csvPath" }
    $clock = [long]$settings.timing.cpu_clock_hz
    if ($clock -le 0) { throw 'WCET configuration must specify a positive cpu_clock_hz.' }
    $record = [ordered]@{
        schema_version = 1
        analysis_kind = 'static_timing_estimate'
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        elf = Resolve-CallerPath $Elf
        elf_sha256 = (Get-FileHash -LiteralPath $Elf -Algorithm SHA256).Hash.ToLowerInvariant()
        config_sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
        csv_sha256 = (Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash.ToLowerInvariant()
        cpu_clock_hz = $clock
        model = if ($Model) { $Model } else { $settings.timing.model }
        include_profiler_hooks = [bool]$settings.instrumentation.include_profiler_hooks
        function_count = $rows.Count
        limitations = 'Conditional timing estimates, not qualified WCET bounds. Review loop bounds, target memory timing, instrumentation and interrupt assumptions.'
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$csvPath.analysis.json" -Encoding UTF8
}

$sewcet = if ($env:SEWCET_DIR) { $env:SEWCET_DIR } else { Join-Path $PSScriptRoot '..\..\sewcet' }
$tool = Join-Path $sewcet 'wcet\run_wcet.ps1'
if (-not (Test-Path -LiteralPath $tool)) {
    $tool = Join-Path $sewcet 'tools\run_wcet.ps1'
}

$selfPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$toolFull = if (Test-Path -LiteralPath $tool) { [System.IO.Path]::GetFullPath($tool) } else { "" }

if ($toolFull -and ($toolFull -ne $selfPath)) {
    $toolArgs = @{
        Config   = $configPath
        WcetOnly = $wcetOnlyFlag
    }
    if ($Elf) { $toolArgs.Elf = Resolve-CallerPath $Elf }
    if ($Out) { $toolArgs.Out = Resolve-CallerPath $Out }
    if ($Model) { $toolArgs.Model = $Model }
    if ($resolvedCompare.Count -gt 0) { $toolArgs.Compare = $resolvedCompare }
    & $tool @toolArgs
    $status = $LASTEXITCODE
    if ($status -eq 0) { Write-AnalysisRecord }
    exit $status
}

function ConvertTo-WslPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    return (& wsl.exe -e wslpath -a ($full -replace '\\', '/')).Trim()
}

$localSh = Join-Path $PSScriptRoot 'run_wcet.sh'
if (-not (Test-Path -LiteralPath $localSh)) {
    throw "run_wcet.sh not found: $localSh"
}

$runner = ConvertTo-WslPath $localSh
$wslArgs = @('-e', 'env')
if ($Elf) {
    $wslArgs += "ELF=$(ConvertTo-WslPath (Resolve-CallerPath $Elf))"
}
if ($wcetOnlyFlag) {
    $wslArgs += "WCET_ONLY=1"
}
if (-not $Elf -and $resolvedCompare.Count -ge 2) {
    $wslArgs += "COMPARE_ONLY=1"
    $wslArgs += "COMPARE_CSV=$(ConvertTo-WslPath $resolvedCompare[0])"
    $wslArgs += "WCET_OUT_CSV=$(ConvertTo-WslPath $resolvedCompare[1])"
    if ($Out) {
        $wslArgs += "COMPARE_OUT_CSV=$(ConvertTo-WslPath (Resolve-CallerPath $Out))"
    }
} else {
    if ($Out) {
        $wslArgs += "WCET_OUT_CSV=$(ConvertTo-WslPath (Resolve-CallerPath $Out))"
    }
    if ($resolvedCompare.Count -ge 1) {
        $wslArgs += "COMPARE_CSV=$(ConvertTo-WslPath $resolvedCompare[0])"
    }
}

$wslArgs += @('bash', $runner, (ConvertTo-WslPath $configPath))
if ($Out -and $Elf) {
    $wslArgs += @('--output', (ConvertTo-WslPath (Resolve-CallerPath $Out)))
}
if ($Model) {
    $wslArgs += @('--model', $Model)
}

& wsl.exe @wslArgs
$status = $LASTEXITCODE
if ($status -eq 0) { Write-AnalysisRecord }
exit $status
