# C: drive cleanup - only regenerable caches / temp data.
# Never touches: app binaries, configs, credentials, chat history, project files, user documents.
$ErrorActionPreference = 'Continue'
$L = $env:LOCALAPPDATA
$A = $env:APPDATA
$PD = 'C:\ProgramData'

function Get-Size($p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return 0 }
    return [double]$s
}

# --- explicitly preserved (documented so nobody "helpfully" adds them later) ---
# $L\Codex / bin, runtimes        -> live program binaries
# $L\SuperBrowser\...\Default     -> profile, cookies, logins
# $L\JianyingPro\User Data\Projects-> user drafts
# $L\ms-playwright                -> browser engines for automation
# $L\Packages, Programs           -> installed UWP / desktop apps
# C:\Windows\Installer            -> MSI/MSP required for uninstall/repair
# C:\Windows\WinSxS               -> hardlinked component store (needs DISM + admin)
# Documents\*, xwechat_files\*    -> user data

$targets = [ordered]@{}

# --- 1. System / OS level ---
if (Test-Path "$L\Temp") {
    Get-ChildItem -LiteralPath "$L\Temp" -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $targets["Temp\$($_.Name)"] = $_.FullName }
}
$targets['Windows Update download cache'] = 'C:\Windows\SoftwareDistribution\Download'
Get-ChildItem -LiteralPath 'C:\Windows\Logs' -Force -ErrorAction SilentlyContinue |
    ForEach-Object { $targets["Windows log\$($_.Name)"] = $_.FullName }
$targets['Thumbnail / icon cache'] = "$L\Microsoft\Windows\Explorer"
$targets['Error reporting queue (user)'] = "$L\Microsoft\Windows\WER"
$targets['Error reporting queue (machine)'] = "$PD\Microsoft\Windows\WER"
$targets['Windows Defender scan cache'] = "$PD\Microsoft\Windows Defender\Scans"
$targets['InstallShield / MSI download cache (user)'] = "$L\Package Cache"
$targets['VS installer package cache'] = "$PD\Package Cache"
$targets['D3D shader cache'] = "$L\D3DSCache"
$targets['NVIDIA OpenGL shader cache'] = "$L\NVIDIA\GLCache"
$targets['NVIDIA DirectX shader cache'] = "$L\NVIDIA\DXCache"
$targets['NVIDIA NV_Cache'] = "$L\NVIDIA\NV_Cache"

# --- 2. Package manager caches (all rebuild on next install) ---
$targets['npm cache'] = "$L\npm-cache"
$targets['npm cache (roaming)'] = "$A\npm-cache"
$targets['node-gyp headers'] = "$L\node-gyp"
$targets['pip cache'] = "$L\pip\Cache"
$targets['pip http cache'] = "$L\pip\http"
$targets['yarn cache'] = "$L\Yarn\Cache"
$targets['pnpm store cache'] = "$L\pnpm\store"

# --- 3. Browser / Electron caches ---
foreach ($b in @('Google\Chrome\User Data\Default\Cache',
                 'Google\Chrome\User Data\Default\Code Cache',
                 'Google\Chrome\User Data\Default\GPUCache',
                 'Google\Chrome\User Data\Default\Service Worker\CacheStorage',
                 'Google\Chrome\User Data\ShaderCache',
                 'Google\Chrome\User Data\GrShaderCache')) {
    $targets["Chrome: $($b.Split('\')[-1])"] = "$L\$b"
}
$targets['Chrome installer cache'] = "$L\Google\Chrome\Installer"
$targets['Chrome update cache'] = "$L\Google\Update\Download"
$targets['Edge update cache'] = "$L\Microsoft\EdgeUpdate\Download"
$targets['WebView2 cache (Microsoft)'] = "$L\Microsoft\Edge\User Data\Default\Cache"
$targets['Steam htmlcache'] = "$L\Steam\htmlcache"

# --- 4. App caches that the apps recreate on demand ---
$targets['DingTalk service-worker cache'] = "$L\DingTalk_108\Service Worker"
$targets['DingTalk code cache'] = "$L\DingTalk_108\Code Cache"
$targets['DingTalk GPUCache'] = "$L\DingTalk_108\GPUCache"
$targets['AliWorkbench temp'] = "$L\AliWorkbenchTemp"
$targets['AlibabaSupplier logs'] = "$L\AlibabaSupplier\log"
$targets['AlibabaSupplier CEF cache'] = "$L\AlibabaSupplier\CEF_90.0.0_2407\Cache"
$targets['SuperBrowser chromium cache'] = "$L\SuperBrowser\User Data\Chromium_27482477394732\Default\Cache"
$targets['SuperBrowser code cache'] = "$L\SuperBrowser\User Data\Chromium_27482477394732\Default\Code Cache"
$targets['SuperBrowser GPU cache'] = "$L\SuperBrowser\User Data\Chromium_27482477394732\Default\GPUCache"
$targets['JianyingPro logs'] = "$L\JianyingPro\User Data\Log"
$targets['JianyingPro CEF cache'] = "$L\JianyingPro\User Data\CEF"
$targets['PyCharm index cache'] = "$L\JetBrains\PyCharm2025.2\caches"
$targets['PyCharm indexes'] = "$L\JetBrains\PyCharm2025.2\index"
$targets['PyCharm jcef cache'] = "$L\JetBrains\PyCharm2025.2\jcef_cache"
$targets['PyCharm logs'] = "$L\JetBrains\PyCharm2025.2\log"
$targets['VSCode cached data'] = "$A\Code\Cache"
$targets['VSCode cached ext data'] = "$A\Code\CachedData"
$targets['VSCode GPUCache'] = "$A\Code\GPUCache"
$targets['VSCode logs'] = "$A\Code\logs"

# --- 5. Downloaded installers left behind by self-updaters ---
Get-ChildItem -LiteralPath $L -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*-updater' } |
    ForEach-Object { $targets["Updater payload: $($_.Name)"] = $_.FullName }
$targets['DSH plugin installer payload'] = "$L\app_shell_cache_2079"
$targets['accio updater payload'] = "$L\accio-updater"

# --- execute ---
$before = (Get-PSDrive C).Free
$results = @()
foreach ($k in $targets.Keys) {
    $p = $targets[$k]
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $sz = Get-Size $p
    if ($sz -le 0) { continue }
    try {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
    } catch {
        # partial failure: retry children one by one
        Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $after = Get-Size $p
    $freed = $sz - $after
    $results += [PSCustomObject]@{
        Target = $k
        FreedMB = [math]::Round($freed / 1MB, 1)
        LeftMB  = [math]::Round($after / 1MB, 1)
    }
}

$end = (Get-PSDrive C).Free
$total = ($end - $before)
"=== CLEANUP RESULT ==="
$results | Where-Object { $_.FreedMB -gt 1 -or $_.LeftMB -gt 5 } | Sort-Object FreedMB -Descending |
    Format-Table -AutoSize
""
"Reclaimed now : {0:N2} GB" -f ($total / 1GB)
"C: free before: {0:N2} GB" -f ($before / 1GB)
"C: free after : {0:N2} GB" -f ($end / 1GB)
