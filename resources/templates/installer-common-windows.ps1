###############################################################################
# ariza installer runtime (Windows / PowerShell)
#
# Inlined verbatim into install.ps1 and uninstall.ps1 at render time, so a
# generated installer is one self-contained file.
#
# Adapted from the pre-bundle installers' template/lib/common-windows.ps1:
# the registry, the package managers and the shortcut helpers are gone (a
# bundle installs none of that), the user-PATH machinery is kept, because
# an unguarded PATH write is how a user ends up with the same directory in
# it eleven times.
#
# Callers must have set: $AppDisplay, $AppExec, $ArizaRoot.
###############################################################################

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ariza-Log  { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Blue }
function Ariza-Ok   { param([string]$Message) Write-Host "ok  $Message" -ForegroundColor Green }
function Ariza-Warn { param([string]$Message) Write-Host "!!  $Message" -ForegroundColor Yellow }

function Ariza-Err {
    param([string]$Message)
    Write-Host "error $Message" -ForegroundColor Red
    exit 1
}

# ---- downloading -------------------------------------------------------------

function Ariza-Download {
    param([string]$Url, [string]$Dest)
    # -UseBasicParsing keeps this working on a Server Core box with no
    # Internet Explorer engine, which is where Invoke-WebRequest's default
    # parser falls over.
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

# ---- checksums ---------------------------------------------------------------

function Ariza-Sha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Ariza-FirstWord {
    param([string]$Path)
    # A `<hex>  <filename>` checksum file, as shasum -c reads.
    $line = (Get-Content -LiteralPath $Path -TotalCount 1)
    if (-not $line) { return '' }
    return ($line -split '\s+')[0].ToLower()
}

function Ariza-VerifySha256 {
    param([string]$Path, [string]$Expected)
    $actual = Ariza-Sha256 $Path
    if ($actual -ne $Expected.ToLower()) {
        Ariza-Err "checksum mismatch for $(Split-Path -Leaf $Path): expected $Expected, got $actual -- not installing"
    }
}

# ---- unpacking ---------------------------------------------------------------

function Ariza-Extract {
    param([string]$Archive, [string]$Into)
    New-Item -ItemType Directory -Path $Into -Force | Out-Null
    if ($Archive.ToLower().EndsWith('.zip')) {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Into -Force
    }
    else {
        # bsdtar has shipped in Windows since 10 1803 and reads .tar.gz,
        # which is what ariza packages every platform's bundle as.
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if (-not $tar) {
            Ariza-Err "need tar.exe (Windows 10 1803 or later) to unpack $(Split-Path -Leaf $Archive)"
        }
        & $tar.Path -x -z -f $Archive -C $Into
        if ($LASTEXITCODE -ne 0) {
            Ariza-Err "tar could not unpack $(Split-Path -Leaf $Archive) (exit $LASTEXITCODE)"
        }
    }
}

# ---- user PATH ---------------------------------------------------------------
#
# The user environment in the registry (HKCU\Environment), never the
# machine one: nothing here needs administrator rights, and nothing here
# should be visible to other accounts.

function Ariza-PersistPath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $current) { $current = '' }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if ($parts -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('PATH', ((@($Dir) + $parts) -join ';'), 'User')
        Ariza-Ok "added $Dir to your PATH"
    }
    if (($env:PATH -split ';') -notcontains $Dir) {
        $env:PATH = "$Dir;$env:PATH"
    }
}

function Ariza-UnpersistPath {
    param([string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $current) { return }
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if ($parts -notcontains $Dir) { return }
    $kept = $parts | Where-Object { $_ -ne $Dir }
    [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
    Ariza-Ok "removed $Dir from your PATH"
}

# ---- the `current` junction --------------------------------------------------
#
# A junction rather than a symbolic link: creating a symlink on Windows
# needs either administrator rights or Developer Mode, and an installer
# that demands either for a per-user install is one nobody runs.

function Ariza-RemoveLink {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.LinkType) {
        Ariza-Err "$Path exists and is not a junction -- move it aside and re-run"
    }
    # .Delete() removes the junction itself; Remove-Item -Recurse would
    # walk through it and delete the target's contents.
    $item.Delete()
}

function Ariza-PointCurrent {
    param([string]$Target)
    $link = Join-Path $ArizaRoot 'current'
    Ariza-RemoveLink $link
    New-Item -ItemType Junction -Path $link -Target $Target | Out-Null
}
