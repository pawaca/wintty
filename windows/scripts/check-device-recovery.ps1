# Compare an unchanged DLL against a candidate through the embedded API.
# The probe removes only its own process's D3D12 device, not the adapter.
param(
    [Parameter(Mandatory)][string]$BaselineDll,
    [Parameter(Mandatory)][string]$CandidateDll,
    [switch]$InLane
)
$ErrorActionPreference = 'Stop'
$BaselineDll = (Resolve-Path -LiteralPath $BaselineDll).Path
$CandidateDll = (Resolve-Path -LiteralPath $CandidateDll).Path
if (!$InLane) {
    $incoda = Join-Path $env:LOCALAPPDATA 'Programs\incoda\incoda.exe'
    if (!(Test-Path $incoda)) { throw 'incoda is required' }
    $env:INCODA_OWNER = 'device-recovery-probe'
    & $incoda run --queue wintty-build,wintty-desktop --exclusive --wait 10m --reason 'isolated multi-surface device recovery regression' -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -BaselineDll $BaselineDll -CandidateDll $CandidateDll -InLane
    exit $LASTEXITCODE
}
$out = Join-Path $env:TEMP ('device-recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
# The embedded probe currently uses defaults only. Keep its children isolated
# as well, so future runtime config reads cannot reach a user's configuration.
$env:XDG_CONFIG_HOME = Join-Path $out 'config'
$env:WINTTY_TEST_CONFIG = '1'
New-Item -ItemType Directory -Path $env:XDG_CONFIG_HOME | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual C++ tools are required' }
$envbat = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
$source = Join-Path $PSScriptRoot 'device-recovery-probe.cpp'
$line = 'call "' + $envbat + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /EHsc /W4 "' + $source + '" /Fo:"' + $out + '\probe.obj" /Fe:"' + $out + '\probe.exe" /link /STACK:8388608'
& cmd.exe /d /c $line
if ($LASTEXITCODE -ne 0) { throw "Probe compilation failed. Evidence: $out" }
$results = @()
foreach ($case in @(@{name='baseline';dll=$BaselineDll}, @{name='candidate';dll=$CandidateDll})) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = "$out\probe.exe"
    $start.Arguments = '"' + $case.dll + '"'
    # Both candidates use the same unchanged runtime assets as the baseline.
    $start.WorkingDirectory = Split-Path $BaselineDll
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $start
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (!$p.WaitForExit(90000)) {
        $p.Kill()
        $p.WaitForExit()
        $code = 'timeout'
    } else { $code = $p.ExitCode }
    [IO.File]::WriteAllText("$out\$($case.name).out", $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText("$out\$($case.name).err", $stderr.GetAwaiter().GetResult())
    $p.Dispose()
    $results += @{name=$case.name;exitCode=$code;sha256=(Get-FileHash $case.dll).Hash;output=[IO.File]::ReadAllText("$out\$($case.name).out")}
    $results | ConvertTo-Json -Depth 4 | Set-Content "$out\results.json"
}
Write-Output "Evidence: $out"
$results | ConvertTo-Json -Depth 4
if ($results[0].exitCode -ne 10) { throw 'The baseline did not reproduce the hidden-reference failure' }
if ($results[1].exitCode -ne 0) { throw 'Candidate recovery regression failed' }
