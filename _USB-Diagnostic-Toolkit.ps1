<#
.SYNOPSIS
    Rebuilds the Ventoy USB toolkit from scratch by downloading everything
    from official sources into the exact same folder structure.

.DESCRIPTION
    Recreates the folder tree of the Ventoy (D:) USB stick and fills it with
    the LATEST version of every tool, resolved live from vendor sites, GitHub
    and TechPowerUp. If a "latest version" lookup fails, the script falls back
    to a known-good pinned URL so the run still completes.
    Files that are already up to date are skipped without re-downloading:
    version-stamped items are matched by name, and fixed-name items are
    tracked in a small hidden state file (.toolkit-state.json).
    When a newer version replaces an older one, the outdated files/folders
    are removed after the new download succeeds, so re-runs keep the
    destination clean. A per-item summary is printed at the end of each run.

.PARAMETER Destination
    Root folder to build into. Default: the folder the script is in.

.PARAMETER SkipLarge
    Skip files larger than ~500 MB (the full NVIDIA driver).
    Useful for a quick test run.

.EXAMPLE
    .\_USB-Diagnostic-Toolkit.ps1 -SkipLarge
    .\_USB-Diagnostic-Toolkit.ps1 -Destination "E:\"
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$SkipLarge
)

if (-not $Destination) {
    $Destination = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Curl      = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $Curl)) {
    throw "curl.exe not found at $Curl - this script requires Windows 10 1803 or newer."
}
$BrowserUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$WingetUA  = 'winget-cli/1.7'   # TechPowerUp allows package-manager user agents on static links
$Results   = [System.Collections.Generic.List[object]]::new()

# Purge temp workspaces left behind by previously interrupted runs, then
# create a fresh one for this run
Get-ChildItem -Path $env:TEMP -Directory -Filter 'UsbRebuild_*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$TempDir   = Join-Path $env:TEMP ("UsbRebuild_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ---------------------------------------------------------------- helpers ---

function New-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Item = $Name; Status = $Status; Detail = $Detail })
    $color = switch ($Status) {
        'OK'      { 'Green' }
        'CURRENT' { 'Cyan' }
        'SKIPPED' { 'Yellow' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$UserAgent = $BrowserUA,
        [string]$Referer
    )
    $part = "$OutFile.part"
    $curlArgs = @('-L', '--fail', '--retry', '2', '--retry-delay', '3',
                  '--connect-timeout', '20', '--progress-bar',
                  '-A', $UserAgent, '-o', $part)
    if ($Referer) { $curlArgs += @('-e', $Referer) }
    $curlArgs += $Url
    & $Curl @curlArgs
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
        throw "curl failed with exit code $LASTEXITCODE for $Url"
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
}

# Extracts a zip. If the zip wraps everything in a single top-level folder,
# its contents are hoisted so the target folder layout matches the USB stick.
function Expand-Smart {
    param(
        [string]$ZipFile,
        [string]$TargetDir,
        [string]$OnlyFile   # copy just this one file from the archive
    )
    $stage = Join-Path $TempDir ([IO.Path]::GetFileNameWithoutExtension($ZipFile) + '_x')
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -LiteralPath $ZipFile -DestinationPath $stage -Force

    if ($OnlyFile) {
        $hit = Get-ChildItem -Path $stage -Recurse -File -Filter $OnlyFile | Select-Object -First 1
        if (-not $hit) { throw "'$OnlyFile' not found inside $ZipFile" }
        New-Dir $TargetDir
        Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $TargetDir $OnlyFile) -Force
        return
    }

    $top = Get-ChildItem -Path $stage -Force
    $src = $stage
    if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }
    New-Dir $TargetDir
    Copy-Item -Path (Join-Path $src '*') -Destination $TargetDir -Recurse -Force
}

# Deletes outdated versions of a tool (files or folders matching $Pattern,
# except the just-downloaded $Keep). Called only after a successful download,
# so a failed update never deletes the working previous version.
function Remove-OldVersions([string]$Dir, [string]$Pattern, [string]$Keep) {
    Get-ChildItem -Path $Dir -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object Name -ne $Keep |
        ForEach-Object {
            Write-Host ("        removed old version: {0}" -f $_.Name) -ForegroundColor DarkGray
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
}

function New-UrlShortcut([string]$Path, [string]$Url) {
    Set-Content -LiteralPath $Path -Value "[InternetShortcut]`r`nURL=$Url`r`n" -Encoding ASCII
    # Windows filenames are case-insensitive, so writing onto an existing
    # shortcut keeps its old casing; rename to enforce the exact name
    $onDisk = Get-Item -LiteralPath $Path
    $wanted = Split-Path $Path -Leaf
    if ($onDisk.Name -cne $wanted) { Rename-Item -LiteralPath $onDisk.FullName -NewName $wanted }
}

function New-LnkShortcut([string]$Path, [string]$Target, [string]$Arguments) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments  = $Arguments
    $lnk.Save()
}

# --------------------------------------------- latest-version resolution ----

# Runs a resolver scriptblock; falls back to a known-good URL if it fails,
# so a broken vendor page never stops the whole rebuild.
function Resolve-Latest {
    param([string]$Name, [scriptblock]$Resolver, [string]$Fallback)
    try {
        $url = & $Resolver
        if (-not $url) { throw 'lookup returned nothing' }
        Write-Host ("  {0,-28} -> {1}" -f $Name, ([uri]$url).Segments[-1]) -ForegroundColor DarkGray
        return $url
    }
    catch {
        Write-Host ("  {0,-28} -> lookup failed, using known version ({1})" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
        return $Fallback
    }
}

function Get-GitHubLatestAssetUrl([string]$Repo, [string]$AssetPattern) {
    $json = (& $Curl -s -A $BrowserUA --connect-timeout 20 --max-time 60 "https://api.github.com/repos/$Repo/releases/latest") -join "`n" | ConvertFrom-Json
    ($json.assets | Where-Object name -match $AssetPattern | Select-Object -First 1).browser_download_url
}

# First regex match on a web page (TechPowerUp/CPUID/HWiNFO list newest first)
function Get-PageMatch([string]$PageUrl, [string]$Regex) {
    $html = (& $Curl -sL -A $BrowserUA --connect-timeout 20 --max-time 60 $PageUrl) -join "`n"
    $m = [regex]::Match($html, $Regex)
    if ($m.Success) { $m.Value } else { $null }
}

# Fingerprint of a remote file (ETag / Last-Modified / total size) obtained
# from a 1-byte range request, so servers that reject HEAD still answer.
# Returns $null when the server gives nothing usable.
function Get-RemoteSignature([string]$Url, [string]$UserAgent = $BrowserUA) {
    $headers = & $Curl -sL -r 0-0 -D - -o NUL -A $UserAgent --connect-timeout 20 --max-time 60 $Url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $headers) { return $null }
    $etag = ''; $lastMod = ''; $size = ''
    foreach ($line in $headers) {
        if ($line -match '^ETag:\s*(.+?)\s*$')                       { $etag = $Matches[1] }
        elseif ($line -match '^Last-Modified:\s*(.+?)\s*$')          { $lastMod = $Matches[1] }
        elseif ($line -match '^Content-Range:\s*bytes\s+\S+/(\d+)')  { $size = $Matches[1] }
    }
    if (-not ($etag -or $lastMod -or $size)) { return $null }
    "$etag|$lastMod|$size"
}

Write-Host "`nResolving latest versions...`n" -ForegroundColor Cyan

$amdUrl = Resolve-Latest 'AMD Adrenalin (web installer)' {
    Get-PageMatch 'https://www.amd.com/en/support/download/drivers.html' 'https://[^"'']*minimalsetup[^"'']*\.exe'
} 'https://drivers.amd.com/drivers/installer/26.10/whql/amd-software-adrenalin-edition-26.6.4-minimalsetup-260628_web.exe'

$cpuzUrl = Resolve-Latest 'CPU-Z' {
    $name = Get-PageMatch 'https://www.cpuid.com/softwares/cpu-z.html' 'cpu-z_[\d\.]+-en\.zip'
    if ($name) { "https://download.cpuid.com/cpu-z/$name" }
} 'https://download.cpuid.com/cpu-z/cpu-z_2.20.2-en.zip'

$dduUrl = Resolve-Latest 'DDU' {
    $name = Get-PageMatch 'https://www.techpowerup.com/download/display-driver-uninstaller-ddu/' 'DDU-v[\d\.]+\.exe'
    if ($name) { "https://us2-dl.techpowerup.com/files/$name" }
} 'https://us2-dl.techpowerup.com/files/DDU-v18.1.5.5.exe'

$gpuzUrl = Resolve-Latest 'GPU-Z' {
    $name = Get-PageMatch 'https://www.techpowerup.com/download/techpowerup-gpu-z/' 'GPU-Z\.[\d\.]+\.exe'
    if ($name) { "https://us2-dl.techpowerup.com/files/$name" }
} 'https://us2-dl.techpowerup.com/files/GPU-Z.2.70.0.exe'

$hwiUrl = Resolve-Latest 'HWiNFO' {
    $name = Get-PageMatch 'https://www.hwinfo.com/download/' 'hwi_\d+\.zip'
    if ($name) { "https://www.hwinfo.com/files/$name" }
} 'https://www.hwinfo.com/files/hwi_850.zip'

# The official Intel page blocks non-browser clients, but Intel's file server
# (downloadmirror.intel.com) does not. The current link is read from the
# newest Wayback Machine snapshot of the page, then fetched from Intel.
$intelUrl = Resolve-Latest 'Intel Chipset INF Utility' {
    Get-PageMatch 'https://web.archive.org/web/2/https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html' `
                  'https?://downloadmirror\.intel\.com/\d+/SetupChipset\.exe'
} 'https://downloadmirror.intel.com/872506/SetupChipset.exe'

$nvcUrl = Resolve-Latest 'NVCleanstall' {
    $name = Get-PageMatch 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/' 'NVCleanstall_[\d\.]+\.exe'
    if ($name) { "https://us2-dl.techpowerup.com/files/$name" }
} 'https://us2-dl.techpowerup.com/files/NVCleanstall_1.19.0.exe'

$nvAppUrl = Resolve-Latest 'NVIDIA App' {
    Get-PageMatch 'https://www.nvidia.com/en-us/software/nvidia-app/' 'https://[^"'']*NVIDIA_app[^"'']*\.exe'
} 'https://us.download.nvidia.com/nvapp/client/11.0.8.299/NVIDIA_app_v11.0.8.299.exe'

$nvDriverUrl = Resolve-Latest 'NVIDIA Game Ready driver' {
    # Official driver lookup API (psid 133 / pfid 1067 = GeForce RTX 5090, osID 135 = Win11 x64)
    # upCRD=0 selects the Game Ready driver (upCRD=1 would be the Studio driver)
    $j = (& $Curl -s -A $BrowserUA --connect-timeout 20 --max-time 60 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=133&pfid=1067&osID=135&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1') -join "`n" | ConvertFrom-Json
    $j.IDS[0].downloadInfo.DownloadURL
} 'https://us.download.nvidia.com/Windows/610.74/610.74-desktop-win10-win11-64bit-international-dch-whql.exe'

$rufusUrl = Resolve-Latest 'Rufus (portable)' {
    Get-GitHubLatestAssetUrl 'pbatard/rufus' '^rufus-[\d\.]+p\.exe$'
} 'https://github.com/pbatard/rufus/releases/download/v4.15/rufus-4.15p.exe'

$ventoyUrl = Resolve-Latest 'Ventoy' {
    Get-GitHubLatestAssetUrl 'ventoy/Ventoy' '^ventoy-[\d\.]+-windows\.zip$'
} 'https://github.com/ventoy/Ventoy/releases/download/v1.1.16/ventoy-1.1.16-windows.zip'

$zenUrl = Resolve-Latest 'ZenTimings' {
    Get-GitHubLatestAssetUrl 'irusanov/ZenTimings' '^ZenTimings_v[\d\.]+\.zip$'
} 'https://github.com/irusanov/ZenTimings/releases/download/v1.39/ZenTimings_v1.39.zip'

# Version-numbered names derived from what was resolved, mirroring the USB layout
$amdFile      = ([uri]$amdUrl).Segments[-1]
$nvDriverFile = ([uri]$nvDriverUrl).Segments[-1]
$nvAppFile    = ([uri]$nvAppUrl).Segments[-1]
$gpuzFile     = ([uri]$gpuzUrl).Segments[-1]
$nvcFile      = ([uri]$nvcUrl).Segments[-1]
$rufusFile    = ([uri]$rufusUrl).Segments[-1]
$dduDirName   = ([uri]$dduUrl).Segments[-1] -replace '^DDU-v([\d\.]+)\.exe$', 'DDU v$1'    # DDU v18.1.5.5
$zenDirName   = [IO.Path]::GetFileNameWithoutExtension(([uri]$zenUrl).Segments[-1])       # ZenTimings_v1.39
$ventoyZip    = ([uri]$ventoyUrl).Segments[-1]                                             # ventoy-1.1.16-windows.zip
$ventoyDir    = [IO.Path]::GetFileNameWithoutExtension($ventoyZip)                         # ventoy-1.1.16-windows
$ventoyInner  = $ventoyDir -replace '-windows$', ''                                        # ventoy-1.1.16

# ------------------------------------------------------------ folder tree ---

Write-Host "`nBuilding folder structure in: $Destination`n" -ForegroundColor Cyan

$ToolkitDir = Join-Path $Destination 'BIOS, drivers, scripts & software'
$Dirs = @{
    Root     = $Destination
    Ventoy   = Join-Path $Destination 'ventoy'
    Backup   = Join-Path $Destination 'Backup Ventoy & Rufus'
    BiosUefi = Join-Path $ToolkitDir 'BIOS UEFI'
    OpSys    = Join-Path $ToolkitDir 'Operating System'
    DrvAmd   = Join-Path $ToolkitDir 'Drivers\AMD'
    DrvIntel = Join-Path $ToolkitDir 'Drivers\Intel'
    DrvNv    = Join-Path $ToolkitDir 'Drivers\NVIDIA'
    Software = Join-Path $ToolkitDir 'Software'
    Scripts  = Join-Path $ToolkitDir 'Scripts'
}
$Dirs.Values | ForEach-Object { New-Dir $_ }

# Clear leftover partial downloads from a previously interrupted run
Get-ChildItem -Path $Destination -Recurse -Filter '*.part' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Up-to-date tracking: remembers which URL produced each fixed-name file so
# unchanged files can be skipped on re-runs (hidden file at the destination)
$StatePath = Join-Path $Destination '.toolkit-state.json'
$State = @{}
if (Test-Path -LiteralPath $StatePath) {
    try {
        (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $State[$_.Name] = $_.Value }
    } catch { }
}

# ------------------------------------------------- plain direct downloads ---

# Clean* keys: after a successful download, older versions matching
# CleanPattern (except the fresh file/folder) are removed from CleanDir.
# Up-to-date detection: items whose file/folder name contains the version are
# marked SkipIfPresent (present = current). Fixed-name items are compared
# against the state file; Static marks items whose URL never changes, so the
# remote file fingerprint decides whether a new download is needed.
# The list is processed in alphabetical order (sorted by Name below).
$Manifest = @(
    @{ Name = "AMD Adrenalin web installer ($amdFile)"; Dir = $Dirs.DrvAmd
       File = $amdFile; Url = $amdUrl; SkipIfPresent = $true
       Referer = 'https://www.amd.com/en/support/download/drivers.html'
       CleanDir = $Dirs.DrvAmd; CleanPattern = 'amd-software-*.exe'; CleanKeep = $amdFile }
    @{ Name = 'CPU-Z (cpuz_x64.exe)'; Dir = $Dirs.Software; Zip = $true; OnlyFile = 'cpuz_x64.exe'
       Url = $cpuzUrl
       CleanDir = $Dirs.Software; CleanPattern = 'cpu-z_*'; CleanKeep = '' }
    # DDU ships as a 7-Zip SFX exe and needs its settings files, so it is
    # unpacked into its own folder
    @{ Name = "DDU ($dduDirName)"; Dir = (Join-Path $Dirs.Software $dduDirName)
       Sfx = $true; SfxMainFile = 'Display Driver Uninstaller.exe'; Ua = $WingetUA; Url = $dduUrl
       SkipIfPresent = $true
       CleanDir = $Dirs.Software; CleanPattern = 'DDU*'; CleanKeep = $dduDirName }
    @{ Name = "GPU-Z ($gpuzFile)"; Dir = $Dirs.Software
       File = $gpuzFile; Ua = $WingetUA; Url = $gpuzUrl; SkipIfPresent = $true
       CleanDir = $Dirs.Software; CleanPattern = 'GPU-Z.*.exe'; CleanKeep = $gpuzFile }
    @{ Name = 'HWiNFO (HWiNFO64.exe)'; Dir = $Dirs.Software; Zip = $true; OnlyFile = 'HWiNFO64.exe'
       Url = $hwiUrl
       CleanDir = $Dirs.Software; CleanPattern = 'hwi_*'; CleanKeep = '' }
    @{ Name = 'Intel Chipset INF Utility (SetupChipset.exe)'; Dir = $Dirs.DrvIntel
       File = 'SetupChipset.exe'; Url = $intelUrl }
    @{ Name = 'Intel Driver & Support Assistant'; Dir = $Dirs.DrvIntel
       File = 'Intel-Driver-and-Support-Assistant-Installer.exe'; Static = $true
       Url = 'https://dsadata.intel.com/installer' }
    @{ Name = 'MemTest86 USB image'; Dir = $Dirs.Root; Zip = $true; OnlyFile = 'memtest86-usb.img'
       Static = $true
       Url = 'https://www.memtest86.com/downloads/memtest86-usb.zip' }
    @{ Name = "NVCleanstall ($nvcFile)"; Dir = $Dirs.Software
       File = $nvcFile; Ua = $WingetUA; Url = $nvcUrl; SkipIfPresent = $true
       CleanDir = $Dirs.Software; CleanPattern = 'NVCleanstall_*.exe'; CleanKeep = $nvcFile }
    @{ Name = "NVIDIA App ($nvAppFile)"; Dir = $Dirs.DrvNv
       File = $nvAppFile; Url = $nvAppUrl; SkipIfPresent = $true
       CleanDir = $Dirs.DrvNv; CleanPattern = 'NVIDIA_app_v*.exe'; CleanKeep = $nvAppFile }
    @{ Name = "NVIDIA Game Ready driver ($nvDriverFile)"; Dir = $Dirs.DrvNv; Large = $true
       File = $nvDriverFile; Url = $nvDriverUrl; SkipIfPresent = $true
       CleanDir = $Dirs.DrvNv; CleanPattern = '*-desktop-win10-win11-*.exe'; CleanKeep = $nvDriverFile }
    @{ Name = 'NVIDIA Profile Inspector (nvidiaProfileInspector.exe)'; Dir = $Dirs.Software; Zip = $true
       OnlyFile = 'nvidiaProfileInspector.exe'; Static = $true
       Url = 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases/latest/download/nvidiaProfileInspector.zip'
       CleanDir = $Dirs.Software; CleanPattern = 'nvidiaProfileInspector'; CleanKeep = '' }
    @{ Name = "Rufus ($rufusFile)"; Dir = $Dirs.Backup
       File = $rufusFile; Url = $rufusUrl; SkipIfPresent = $true
       CleanDir = $Dirs.Backup; CleanPattern = 'rufus-*.exe'; CleanKeep = $rufusFile }
    @{ Name = "Ventoy ($ventoyInner)"; Dir = (Join-Path $Dirs.Backup "$ventoyDir\$ventoyInner"); Zip = $true
       Url = $ventoyUrl; SkipIfPresent = $true
       CleanDir = $Dirs.Backup; CleanPattern = 'ventoy-*-windows'; CleanKeep = $ventoyDir }
    # ZenTimings needs its bundled DLLs, so it gets its own folder
    @{ Name = "ZenTimings ($zenDirName)"; Dir = (Join-Path $Dirs.Software $zenDirName); Zip = $true
       Url = $zenUrl; SkipIfPresent = $true
       CleanDir = $Dirs.Software; CleanPattern = 'ZenTimings_v*'; CleanKeep = $zenDirName }
) | Sort-Object { $_.Name }

Write-Host "Downloading files...`n" -ForegroundColor Cyan

foreach ($item in $Manifest) {
    try {
        if ($SkipLarge -and $item.Large) {
            Add-Result $item.Name 'SKIPPED' 'large file, -SkipLarge was specified'
            continue
        }
        $ua = if ($item.Ua) { $item.Ua } else { $BrowserUA }

        # ---- up-to-date check: skip when the local copy is already current ----
        $artifact = if ($item.File)     { Join-Path $item.Dir $item.File }
                    elseif ($item.OnlyFile) { Join-Path $item.Dir $item.OnlyFile }
                    else                { $item.Dir }
        $exists = Test-Path -LiteralPath $artifact
        if ($exists -and -not ($item.File -or $item.OnlyFile)) {
            # folder artifacts only count when they have contents
            $exists = @(Get-ChildItem -LiteralPath $artifact -Force -ErrorAction SilentlyContinue).Count -gt 0
        }
        if ($exists) {
            $upToDate = $null
            $prev = $State[$item.Name]
            if ($item.SkipIfPresent) {
                $upToDate = 'latest version already present'
            }
            elseif ($prev -and $prev.Url -eq $item.Url) {
                if ($item.Static) {
                    $sig = Get-RemoteSignature $item.Url $ua
                    if ($sig -and $sig -eq $prev.Sig) { $upToDate = 'remote file unchanged' }
                }
                else {
                    $upToDate = 'already downloaded from this version'
                }
            }
            if ($upToDate) {
                Add-Result $item.Name 'CURRENT' $upToDate
                continue
            }
        }

        if ($item.Zip) {
            $zipPath = Join-Path $TempDir (([uri]$item.Url).Segments[-1])
            Invoke-Download -Url $item.Url -OutFile $zipPath -UserAgent $ua -Referer $item.Referer
            Expand-Smart -ZipFile $zipPath -TargetDir $item.Dir -OnlyFile $item.OnlyFile
        }
        elseif ($item.Sfx) {
            # 7-Zip self-extracting exe: run silently, copy unpacked app folder
            $sfxPath = Join-Path $TempDir (([uri]$item.Url).Segments[-1])
            Invoke-Download -Url $item.Url -OutFile $sfxPath -UserAgent $ua -Referer $item.Referer
            $stage = Join-Path $TempDir ([IO.Path]::GetFileNameWithoutExtension($sfxPath) + '_x')
            $proc = Start-Process -FilePath $sfxPath -ArgumentList '-y', "-o`"$stage`"" -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(120000)) { $proc.Kill(); throw 'self-extractor timed out' }
            $mainExe = Get-ChildItem -Path $stage -Recurse -File -Filter $item.SfxMainFile | Select-Object -First 1
            if (-not $mainExe) { throw "'$($item.SfxMainFile)' not found after extraction" }
            New-Dir $item.Dir
            Copy-Item -Path (Join-Path $mainExe.DirectoryName '*') -Destination $item.Dir -Recurse -Force
        }
        else {
            Invoke-Download -Url $item.Url -OutFile (Join-Path $item.Dir $item.File) -UserAgent $ua -Referer $item.Referer
        }
        Add-Result $item.Name 'OK'
        $State[$item.Name] = @{
            Url = $item.Url
            Sig = if ($item.Static) { Get-RemoteSignature $item.Url $ua } else { $null }
        }
        if ($item.CleanPattern) {
            Remove-OldVersions $item.CleanDir $item.CleanPattern $item.CleanKeep
        }
    }
    catch {
        Add-Result $item.Name 'FAILED' $_.Exception.Message
    }
}

# Persist the up-to-date tracking state (hidden file; recreated each run)
try {
    if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -Force }
    $State | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
    (Get-Item -LiteralPath $StatePath -Force).Attributes = 'Hidden, Archive'
}
catch { }

# ----------------------------------------- recreated shortcuts and configs --

Write-Host "`nRecreating shortcuts and Ventoy configuration..." -ForegroundColor Cyan
try {
    Set-Content -LiteralPath (Join-Path $Dirs.Ventoy 'ventoy.json') -Encoding ASCII -Value @'
{
    "control":[
        { "VTOY_DEFAULT_KBD_LAYOUT": "DANISH" }
    ],
    "theme":{
        "gfxmode": "1920x1080"
    }
}
'@
    Set-Content -LiteralPath (Join-Path $Dirs.Ventoy 'ventoy_backup.json') -Encoding ASCII -Value @'
{
    "control":[
        { "VTOY_DEFAULT_KBD_LAYOUT": "DANISH" }
    ],
    "theme":{
        "gfxmode": "max"
    }
}
'@

    New-UrlShortcut (Join-Path $Dirs.BiosUefi 'VGA BIOS Collection.url')         'https://www.techpowerup.com/vgabios/'
    New-UrlShortcut (Join-Path $Dirs.DrvAmd   'AMD.url')                         'https://www.amd.com/en/support/download/drivers.html'
    New-UrlShortcut (Join-Path $Dirs.DrvIntel 'Intel - Automatic.url')           'https://www.intel.com/content/www/us/en/support/detect.html'
    New-UrlShortcut (Join-Path $Dirs.DrvIntel 'Intel - Chipset INF Utility.url') 'https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html'
    New-UrlShortcut (Join-Path $Dirs.DrvNv    'Nvidia Drivers.url')              'https://www.nvidia.com/en-us/drivers/'
    New-UrlShortcut (Join-Path $Dirs.OpSys    'Windows OS.url')                  'https://www.microsoft.com/en-us/software-download'

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    New-LnkShortcut (Join-Path $Dirs.Scripts 'MAS.lnk')                       $ps '-NoExit -ExecutionPolicy Bypass -Command "irm https://get.activated.win | iex"'
    New-LnkShortcut (Join-Path $Dirs.Scripts 'Winutil.lnk')                   $ps '-ExecutionPolicy Bypass -Command "irm ''https://christitus.com/win'' | iex"'
    New-LnkShortcut (Join-Path $Dirs.Scripts 'USB latency analyzer.lnk')      $ps '-NoExit -ExecutionPolicy Bypass -Command "irm https://tools.mariusheier.com/cpudirect.ps1 | iex"'
    New-LnkShortcut (Join-Path $Dirs.Scripts 'USB polling rate analyzer.lnk') $ps '-NoExit -ExecutionPolicy Bypass -Command "irm https://tools.mariusheier.com/deeppoll.ps1 | iex"'

    Add-Result 'Shortcuts (.url/.lnk) + ventoy.json configs' 'OK'
}
catch {
    Add-Result 'Shortcuts (.url/.lnk) + ventoy.json configs' 'FAILED' $_.Exception.Message
}

# ----------------------------------------------------------------- summary --

Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n===================== SUMMARY =====================" -ForegroundColor Cyan
$Results | Format-Table -AutoSize
$ok      = @($Results | Where-Object Status -eq 'OK').Count
$current = @($Results | Where-Object Status -eq 'CURRENT').Count
$fail    = @($Results | Where-Object Status -eq 'FAILED').Count
$skip    = @($Results | Where-Object Status -eq 'SKIPPED').Count
Write-Host ("{0} downloaded, {1} already up to date, {2} failed, {3} skipped." -f $ok, $current, $fail, $skip) -ForegroundColor Cyan
