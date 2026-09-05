[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$HeadlessTest,
    [switch]$Background,
    [ValidateRange(0, 65535)]
    [int]$MonitorPort = 0,
    [string]$SerialLog = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$image = Join-Path $repositoryRoot 'build\tanebi95.img'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Profile release
}

$qemuCandidates = @(
    'C:\Program Files\qemu\qemu-system-x86_64.exe',
    'C:\Program Files (x86)\qemu\qemu-system-x86_64.exe'
)
$qemuCommand = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
$qemu = if ($qemuCommand) { $qemuCommand.Source } else {
    $qemuCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $qemu) { throw 'QEMU was not found.' }

$qemuRoot = Split-Path -Parent $qemu
$firmwareCandidates = @(
    (Join-Path $qemuRoot 'share\edk2-x86_64-code.fd'),
    (Join-Path $qemuRoot 'share\edk2-x86_64-secure-code.fd'),
    (Join-Path $qemuRoot 'share\OVMF_CODE.fd')
)
$firmware = $firmwareCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $firmware) { throw "No x86-64 UEFI firmware found below $qemuRoot." }

$arguments = @(
    '-machine', 'q35',
    '-m', '256M',
    '-drive', "if=pflash,format=raw,readonly=on,file=$firmware",
    '-drive', "format=raw,file=$image",
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'
)

if ($HeadlessTest) { $arguments += '-no-reboot' }

if ($HeadlessTest -or -not $SerialLog) {
    $arguments += @('-serial', 'stdio')
}
else {
    $arguments += @('-serial', "file:$SerialLog")
}

if ($MonitorPort -gt 0) {
    $arguments += @('-monitor', "tcp:127.0.0.1:$MonitorPort,server=on,wait=off")
}
else {
    $arguments += @('-monitor', 'none')
}
if ($HeadlessTest -or $Background) { $arguments += @('-display', 'none') }

if ($HeadlessTest) {
    $qemuOutput = & $qemu @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $qemuOutput | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 33) { throw "QEMU exited with code $exitCode; expected 33." }
    if (($qemuOutput -join "`n") -notmatch 'TANEBI95_BARE_METAL_OK') {
        throw 'QEMU did not reach the bare-metal handoff marker.'
    }
    Write-Host '[ok] QEMU booted TANEBI 95 and observed the native test exit.'
    return
}

& $qemu @arguments
