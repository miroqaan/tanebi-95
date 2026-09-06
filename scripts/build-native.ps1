[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Profile = 'release',
    [switch]$QemuTest,
    [string]$LanguageRoot = '',
    [switch]$NoMedia
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $LanguageRoot) { $LanguageRoot = Join-Path (Split-Path -Parent $repositoryRoot) 'tanebi-lang' }
$LanguageRoot = (Resolve-Path -LiteralPath $LanguageRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $LanguageRoot 'cmd\tanebi\main.go'))) {
    throw 'TANEBI compiler source was not found. Set -LanguageRoot to tanebi-lang.'
}
$buildRoot = Join-Path $repositoryRoot 'build'
$generated = Join-Path $buildRoot 'generated'
$efiBootRoot = Join-Path $buildRoot 'esp\EFI\BOOT'
New-Item -ItemType Directory -Force -Path $buildRoot, $generated, $efiBootRoot | Out-Null
$mediaPath = Join-Path $buildRoot 'player-native.tmv'
if ($NoMedia -or -not (Test-Path -LiteralPath $mediaPath)) {
    $mediaPath = Join-Path $generated 'empty-media.tmv'
    [IO.File]::WriteAllBytes($mediaPath, [byte[]]::new(0))
}
if ((Get-Item -LiteralPath $mediaPath).Length -gt 0) {
    $reader = [IO.File]::OpenRead($mediaPath)
    try {
        $header = [byte[]]::new(4)
        [void]$reader.Read($header, 0, 4)
        if ([Text.Encoding]::ASCII.GetString($header) -ne 'TNV3') {
            throw 'Native media must use TNV3. Run scripts/prepare-media.ps1 again.'
        }
    } finally { $reader.Dispose() }
}
$go = (Get-Command go -ErrorAction Stop).Source
$rustc = (Get-Command rustc -ErrorAction Stop).Source
$rustup = (Get-Command rustup -ErrorAction Stop).Source
& $rustup target add x86_64-unknown-uefi
if ($LASTEXITCODE -ne 0) { throw 'Rust UEFI code-generation target is unavailable.' }
$compiler = Join-Path $generated 'tanebi.exe'
Push-Location $LanguageRoot
try {
    & $go build -trimpath -o $compiler ./cmd/tanebi
    if ($LASTEXITCODE -ne 0) { throw 'TANEBI compiler build failed.' }
} finally { Pop-Location }
$kernelSources = @('uefi', 'kernel', 'font', 'input', 'desktop', 'player', 'sound') |
    ForEach-Object { Join-Path $repositoryRoot "system\$_.tanebi" }
$bootSources = @('uefi', 'boot') | ForEach-Object { Join-Path $repositoryRoot "system\$_.tanebi" }
$kernelRust = Join-Path $generated 'kernel.rs'
$bootRust = Join-Path $generated 'boot.rs'
$kernelEfi = Join-Path $buildRoot 'esp\KERNEL.EFI'
$bootEfi = Join-Path $efiBootRoot 'BOOTX64.EFI'
$testValue = if ($QemuTest) { '1' } else { '0' }
Write-Host 'Compiling TANEBI OS sources to native backend...'
& $compiler emit -target uefi -entry entry -o $kernelRust -asset "MEDIA=$mediaPath" -define "TEST=$testValue" @kernelSources
if ($LASTEXITCODE -ne 0) { throw 'TANEBI kernel compilation failed.' }
& $compiler emit -target uefi -entry entry -o $bootRust @bootSources
if ($LASTEXITCODE -ne 0) { throw 'TANEBI boot manager compilation failed.' }
$optimization = if ($Profile -eq 'release') { '2' } else { '0' }
$rustOptions = @('--edition=2024', '--target', 'x86_64-unknown-uefi', '-C', "opt-level=$optimization", '-C', 'panic=abort', '-C', 'codegen-units=1')
Write-Host 'Generating UEFI machine code from compiler output...'
& $rustc @rustOptions --crate-name tanebi95_kernel $kernelRust -o $kernelEfi
if ($LASTEXITCODE -ne 0) { throw 'Native kernel backend failed.' }
& $rustc @rustOptions --crate-name tanebi95_boot $bootRust -o $bootEfi
if ($LASTEXITCODE -ne 0) { throw 'Native boot manager backend failed.' }
$shellEfi = Join-Path $repositoryRoot 'third_party\edk2-shell\Shell.efi'
$doomEfi = Join-Path $repositoryRoot 'third_party\uefidoom\prebuilt\doom.efi'
$doomWad = Join-Path $repositoryRoot 'assets\freedoom2.wad'
$startup = Join-Path $repositoryRoot 'assets\startup.nsh'
$imagePath = Join-Path $buildRoot 'tanebi95.img'
Push-Location $repositoryRoot
try {
    & $go run ./tools/mkfat16 $bootEfi $kernelEfi $shellEfi $doomEfi $doomWad $startup $imagePath
    if ($LASTEXITCODE -ne 0) { throw 'FAT16 image creation failed.' }
} finally { Pop-Location }
$sourceRecords = @($kernelSources + $bootSources | Sort-Object -Unique | ForEach-Object {
    [ordered]@{ path = $_.Substring($repositoryRoot.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$provenance = [ordered]@{
    sourceLanguage = 'TANEBI'; backend = 'generated Rust -> rustc/LLVM -> x86-64 UEFI'
    handwrittenRustKernelUsed = $false; testMode = [bool]$QemuTest
    compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
    sources = $sourceRecords
    imageSha256 = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash
    media = [ordered]@{ path = $mediaPath; bytes = (Get-Item -LiteralPath $mediaPath).Length }
    externalPayloads = @('UEFI DOOM', 'Freedoom Phase 2', 'EDK II Shell')
}
[IO.File]::WriteAllText((Join-Path $buildRoot 'native-provenance.json'), ($provenance | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "TANEBI boot manager: $bootEfi"
Write-Host "TANEBI kernel: $kernelEfi"
Write-Host "Boot image: $imagePath"
