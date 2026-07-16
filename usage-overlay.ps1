# usage-overlay.ps1
# Floating click-through overlay showing coding-agent usage across Claude,
# Codex, Cursor, Copilot and OpenCode.
# Run:  powershell -WindowStyle Hidden -File usage-overlay.ps1  (or start-overlay.vbs)
# Stop: powershell -File stop-overlay.ps1   (or the tray icon's Exit)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $dir 'usage-overlay.pid'

# Kill a previous instance if one is still alive
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid -and $oldPid -ne $PID) {
        try { Stop-Process -Id ([int]$oldPid) -Force -Confirm:$false -ErrorAction Stop } catch {}
    }
}
Set-Content -Path $pidFile -Value $PID -Encoding ascii

# node.exe for the Cursor/OpenCode helper scripts: prefer whatever is on
# PATH (nvm, scoop, winget, ...), fall back to the default installer path.
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe -and (Test-Path 'C:\Program Files\nodejs\node.exe')) {
    $nodeExe = 'C:\Program Files\nodejs\node.exe'
}

# ---------- config ----------

# Optional config.json next to the script; any key below can be overridden.
# "sections": "auto" shows only the tools with local data on this machine,
# or list them explicitly, e.g. ["claude", "codex"].
$cfg = @{
    corner          = 'top-right'   # top-right | top-left | bottom-right | bottom-left
    marginX         = 14
    marginY         = 14
    refreshSeconds  = 60
    sections        = 'auto'
    githubUser      = ''
    githubToken     = ''
    copilotIncluded = 200   # monthly AI credits included in your Copilot plan
}
$cfgFile = Join-Path $dir 'config.json'
if (Test-Path $cfgFile) {
    try {
        $userCfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $userCfg.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch {}
}
if ($cfg.corner -notin @('top-right', 'top-left', 'bottom-right', 'bottom-left')) { $cfg.corner = 'top-right' }
# A bad config.json value (typo, wrong type) must never stop the overlay from
# showing up at all: fall back to the default for that one key instead.
try { $cfg.refreshSeconds = [Math]::Max(15, [int]$cfg.refreshSeconds) } catch { $cfg.refreshSeconds = 60 }
try { $cfg.marginX = [double]$cfg.marginX } catch { $cfg.marginX = 14 }
try { $cfg.marginY = [double]$cfg.marginY } catch { $cfg.marginY = 14 }

# Which sections to show is decided from the provider registry further down
# (each provider knows how to detect itself); see $providers / $enabledProviders.

# ---------- data ----------

# Shared HTTP-status -> user-facing label mapping, so the wording stays
# consistent with the ERRORS legend in the help panel across sources.
function Get-HttpErrLabel([int]$status, [hashtable]$extra = @{}) {
    if ($extra.ContainsKey($status)) { return $extra[$status] }
    switch ($status) {
        401 { return 'auth stale' }
        429 { return 'rate limited' }
        default { return 'offline' }
    }
}

function Get-ClaudeUsage {
    try {
        $cred = (Get-Content "$env:USERPROFILE\.claude\.credentials.json" -Raw | ConvertFrom-Json).claudeAiOauth
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 8 -Headers @{
            Authorization    = "Bearer $($cred.accessToken)"
            'anthropic-beta' = 'oauth-2025-04-20'
        }
        $rows = @()
        $fiveHourResets = if ($r.five_hour.resets_at) { [datetime]$r.five_hour.resets_at } else { $null }
        $weekResets = if ($r.seven_day.resets_at) { [datetime]$r.seven_day.resets_at } else { $null }
        $rows += [pscustomobject]@{ Label = '5h '; Pct = [double]$r.five_hour.utilization; Resets = $fiveHourResets }
        $rows += [pscustomobject]@{ Label = 'wk '; Pct = [double]$r.seven_day.utilization; Resets = $weekResets }
        foreach ($lim in $r.limits) {
            if ($lim.kind -eq 'weekly_scoped' -and $lim.scope.model.display_name) {
                $name = $lim.scope.model.display_name.ToLower().Substring(0, [Math]::Min(3, $lim.scope.model.display_name.Length))
                $resets = if ($lim.resets_at) { [datetime]$lim.resets_at } else { $null }
                $rows += [pscustomobject]@{ Label = $name; Pct = [double]$lim.percent; Resets = $resets }
            }
        }
        return @{ ok = $true; rows = $rows }
    } catch {
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        return @{ ok = $false; err = (Get-HttpErrLabel $status) }
    }
}

function Get-CodexUsage {
    try {
        $newest = Get-ChildItem "$env:USERPROFILE\.codex\sessions" -Recurse -File -Filter 'rollout-*.jsonl' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($f in $newest) {
            $line = Get-Content $f.FullName | Where-Object { $_ -match '"rate_limits"' } | Select-Object -Last 1
            if (-not $line) { continue }
            $rl = ($line | ConvertFrom-Json).payload.rate_limits
            if (-not $rl) { continue }
            $epoch = [DateTimeOffset]::FromUnixTimeSeconds(0)
            $rows = @()
            if ($rl.primary) {
                $rows += [pscustomobject]@{ Label = '5h '; Pct = [double]$rl.primary.used_percent; Resets = $epoch.AddSeconds($rl.primary.resets_at).LocalDateTime }
            }
            if ($rl.secondary) {
                $rows += [pscustomobject]@{ Label = 'wk '; Pct = [double]$rl.secondary.used_percent; Resets = $epoch.AddSeconds($rl.secondary.resets_at).LocalDateTime }
            }
            return @{ ok = $true; rows = $rows; asof = $f.LastWriteTime }
        }
        return @{ ok = $false; err = 'no session data' }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

function Get-CursorUsage {
    try {
        if (-not $nodeExe) { return @{ ok = $false; err = 'node missing' } }
        $json = & $nodeExe (Join-Path $dir 'cursor-usage.js')
        if (-not $json) { return @{ ok = $false; err = 'no data' } }
        $j = $json | ConvertFrom-Json
        if ($j.error) { return @{ ok = $false; err = 'fetch failed' } }
        $rows = @(
            [pscustomobject]@{ Label = 'api'; Pct = [double]$j.api; Resets = [datetime]$j.resets },
            [pscustomobject]@{ Label = 'tot'; Pct = [double]$j.total; Resets = [datetime]$j.resets }
        )
        return @{ ok = $true; rows = $rows }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

function Get-CopilotUsage {
    # GitHub Copilot AI-credit usage for a personal account, from the
    # official billing report. Needs in config.json: githubUser, githubToken
    # (fine-grained PAT with Plan: read-only) and copilotIncluded (monthly
    # included AI credits; the API only reports consumption, not the limit).
    try {
        if ("$($cfg.githubUser)" -eq '' -or "$($cfg.githubToken)" -eq '') { return @{ ok = $false; err = 'no token' } }
        $now = [datetime]::UtcNow
        $uri = "https://api.github.com/users/$($cfg.githubUser)/settings/billing/ai_credit/usage?year=$($now.Year)&month=$($now.Month)"
        $r = Invoke-RestMethod -Uri $uri -TimeoutSec 8 -Headers @{
            Authorization          = "Bearer $($cfg.githubToken)"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2026-03-10'
        }
        $used = 0.0
        foreach ($item in $r.usageItems) {
            if (-not $item.product -or $item.product -eq 'copilot') { $used += [double]$item.grossQuantity }
        }
        $included = try { [double]$cfg.copilotIncluded } catch { 200.0 }
        $pct = if ($included -gt 0) { $used / $included * 100 } else { 0 }
        # AI credits reset on the 1st of each month, 00:00 UTC
        $resets = [datetime]::new($now.Year, $now.Month, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMonths(1)
        $rows = @(
            [pscustomobject]@{ Label = 'mo '; Pct = $pct; Resets = $resets }
        )
        return @{ ok = $true; rows = $rows }
    } catch {
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        # 403 here is almost always a PAT missing the "Plan" read permission,
        # not GitHub's secondary rate limit, so it gets its own label rather
        # than being lumped in with 429.
        $err = Get-HttpErrLabel $status @{ 403 = 'no permission'; 404 = 'check user' }
        return @{ ok = $false; err = $err }
    }
}

function Get-OpenCodeUsage {
    # OpenCode Zen has no quota API from the local key, so we show locally
    # tracked spend instead of a % bar (rendered as a plain text line).
    try {
        if (-not $nodeExe) { return @{ ok = $false; err = 'node missing' } }
        $json = & $nodeExe (Join-Path $dir 'opencode-usage.js')
        if (-not $json) { return @{ ok = $false; err = 'no data' } }
        $j = $json | ConvertFrom-Json
        if ($j.error) { return @{ ok = $false; err = 'read failed' } }
        $text = @(
            ('mo ${0:N2} spent' -f [double]$j.month),
            ('all ${0:N2} / {1:N1}M tok' -f [double]$j.total, (([double]$j.tin + [double]$j.tout) / 1e6))
        )
        return @{ ok = $true; textRows = $text }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

# ---------- provider registry ----------

# One row per source. Adding a provider is one entry here, nothing else:
#   key      stable id, also the config.json "sections" name and cache key
#   name     6-char label drawn in the overlay
#   remote   $true = hits a rate-limited network API (fetched every 3rd tick),
#            $false = cheap local read (fetched every tick)
#   detect   scriptblock, $true when this tool has usable data/config here
#   autoHide $true = never shown by the "nothing detected" fallback (needs
#            explicit config, e.g. a token, so it can't just appear)
#   fn       name of the fetch function, invoked by name in a background runspace
$providers = @(
    @{ key = 'claude';   name = 'CLAUDE'; remote = $true;  fn = 'Get-ClaudeUsage'
       detect = { Test-Path "$env:USERPROFILE\.claude\.credentials.json" } }
    @{ key = 'codex';    name = 'CODEX '; remote = $false; fn = 'Get-CodexUsage'
       detect = { Test-Path "$env:USERPROFILE\.codex\sessions" } }
    @{ key = 'cursor';   name = 'CURSOR'; remote = $true;  fn = 'Get-CursorUsage'
       detect = { Test-Path "$env:APPDATA\Cursor\User\globalStorage\state.vscdb" } }
    @{ key = 'copilot';  name = 'COPILT'; remote = $true;  fn = 'Get-CopilotUsage'; autoHide = $true
       detect = { "$($cfg.githubToken)" -ne '' -and "$($cfg.githubUser)" -ne '' } }
    @{ key = 'opencode'; name = 'OPENCD'; remote = $false; fn = 'Get-OpenCodeUsage'
       detect = { Test-Path "$env:USERPROFILE\.local\share\opencode\opencode.db" } }
)

# Resolve the enabled providers once, in registry order.
if ("$($cfg.sections)" -eq 'auto') {
    $enabledProviders = @($providers | Where-Object { & $_.detect })
    # nothing detected at all: fall back to everything that can run without
    # extra config (so an unconfigured Copilot never shows a permanent error)
    if (-not $enabledProviders) { $enabledProviders = @($providers | Where-Object { -not $_.autoHide }) }
} else {
    $wanted = @($cfg.sections | ForEach-Object { "$_".ToLower() })
    $enabledProviders = @($providers | Where-Object { $wanted -contains $_.key })
}

# ---------- rendering helpers ----------

function Format-Reset($t) {
    if (-not $t) { return '--' }
    $span = $t.ToLocalTime() - (Get-Date)
    if ($span.TotalMinutes -le 0) { return 'now' }
    if ($span.TotalHours -lt 1) { return ('{0}m' -f [Math]::Ceiling($span.TotalMinutes)) }
    if ($span.TotalHours -ge 48) { return ('{0}d' -f [Math]::Round($span.TotalDays)) }
    return ('{0}h' -f [Math]::Round($span.TotalHours))
}

function Get-Bar([double]$pct) {
    $filled = [Math]::Round([Math]::Min($pct, 100) / 10)
    return ('#' * $filled) + ('-' * (10 - $filled))
}

function Get-PctColor([double]$pct) {
    if ($pct -ge 85) { return '#FF7B72' }
    if ($pct -ge 60) { return '#E3B341' }
    return '#7EE787'
}

# ---------- window ----------

function New-XamlWindow([string]$xamlText) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    return [Windows.Markup.XamlReader]::Load($reader)
}

$window = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        ShowActivated="False" ResizeMode="NoResize">
  <Border Background="#B40D1117" CornerRadius="6" Padding="12,9,12,9"
          BorderBrush="#28FFFFFF" BorderThickness="1">
    <TextBlock x:Name="Body" FontFamily="Consolas" FontSize="13"
               Foreground="#E6EDF3" LineHeight="19" Text="loading..."/>
  </Border>
</Window>
'@
$body = $window.FindName('Body')

# Tiny always-on-top "?" button (a separate window because the overlay is
# click-through and can't receive clicks itself).
$btnWindow = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        ShowActivated="False" ResizeMode="NoResize" Cursor="Hand">
  <!-- outer grid is a generous, near-invisible hit area so the click is easy -->
  <Grid Width="30" Height="30" Background="#01FFFFFF">
    <Border Width="20" Height="20" CornerRadius="10" Background="#B40D1117"
            BorderBrush="#40FFFFFF" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center">
      <TextBlock Text="?" FontFamily="Consolas" FontSize="12" Foreground="#C9D1D9"
                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </Grid>
</Window>
'@

# The info panel (hidden until the button is clicked).
$panel = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="Height"
        ShowActivated="False" ResizeMode="NoResize" Width="452">
  <Border Background="#F00A0D12" CornerRadius="8" Padding="16,13,16,14"
          BorderBrush="#33FFFFFF" BorderThickness="1">
    <TextBlock x:Name="PanelBody" FontFamily="Consolas" FontSize="12"
               Foreground="#C9D1D9" LineHeight="17" TextWrapping="Wrap"/>
  </Border>
</Window>
'@
$panelBody = $panel.FindName('PanelBody')

# Click-through / no-activate / no-alt-tab styling.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Ex {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@
$GWL_EXSTYLE = -20
$WS_EX_TRANSPARENT = 0x20      # clicks pass through
$WS_EX_TOOLWINDOW  = 0x80      # hide from alt-tab
$WS_EX_LAYERED     = 0x80000
$WS_EX_NOACTIVATE  = 0x08000000 # never steal focus from the user's app

function Set-ExStyle($win, [int]$add) {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $ex = [Win32Ex]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [Win32Ex]::SetWindowLong($hwnd, $GWL_EXSTYLE, $ex -bor $add) | Out-Null
}

# Toggle only the click-through bit, so the overlay can catch the mouse
# while Ctrl is held (to be dragged) and go back to click-through after.
function Set-ClickThrough($win, [bool]$on) {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $ex = [Win32Ex]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    $ex = if ($on) { $ex -bor $WS_EX_TRANSPARENT } else { $ex -band (-bnot $WS_EX_TRANSPARENT) }
    [Win32Ex]::SetWindowLong($hwnd, $GWL_EXSTYLE, $ex) | Out-Null
}

$window.Add_SourceInitialized({
    Set-ExStyle $window ($WS_EX_TRANSPARENT -bor $WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})
$btnWindow.Add_SourceInitialized({
    # clickable, so NOT transparent
    Set-ExStyle $btnWindow ($WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})
$panel.Add_SourceInitialized({
    Set-ExStyle $panel ($WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})

function Add-Run([string]$text, [string]$color) {
    $run = New-Object System.Windows.Documents.Run($text)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $body.Inlines.Add($run) | Out-Null
}

function Add-Panel([string]$text, [string]$color, [bool]$bold = $false) {
    $run = New-Object System.Windows.Documents.Run($text)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($color))
    if ($bold) { $run.FontWeight = [System.Windows.FontWeights]::Bold }
    $panelBody.Inlines.Add($run) | Out-Null
}

# Build the (static) reference text once.
function Build-Panel {
    $H = '#58A6FF'; $M = '#8B949E'; $T = '#C9D1D9'
    $GREEN = '#7EE787'; $AMBER = '#E3B341'; $RED = '#FF7B72'

    Add-Panel "USAGE OVERLAY" $T $true
    Add-Panel "  quota across your coding agents`n`n" $M

    Add-Panel "COLORS`n" $H $true
    Add-Panel "  " $M; Add-Panel "green" $GREEN; Add-Panel " <60%   " $M
    Add-Panel "amber" $AMBER; Add-Panel " 60-84%   " $M
    Add-Panel "red" $RED; Add-Panel " 85%+`n" $M
    Add-Panel "  amber section name = cached, not live`n`n" $M

    Add-Panel "BAR, RESET & MOVE`n" $H $true
    Add-Panel "  ##---- = 10 cells, ~10% each   " $M
    Add-Panel "r 3h / 45m / now" $T; Add-Panel " = time to reset`n" $M
    Add-Panel "  Ctrl+drag to move (position saved)   tray icon: refresh, restart, exit`n`n" $M

    Add-Panel "REFRESH`n" $H $true
    Add-Panel "  every $($cfg.refreshSeconds)s; " $M
    Add-Panel "CLAUDE/CURSOR/COPILT" $T; Add-Panel " (remote) every 3rd tick`n" $M
    Add-Panel "  on failure, keeps the last value (" $M; Add-Panel "amber" $AMBER
    Add-Panel "), cached to disk`n`n" $M

    Add-Panel "SOURCES`n" $H $true
    Add-Panel "  CLAUDE" $T; Add-Panel "   Anthropic OAuth token   " $M; Add-Panel "5h/wk/fab`n" $T
    Add-Panel "  CODEX" $T; Add-Panel "   last local session log   " $M; Add-Panel "5h/wk`n" $T
    Add-Panel "  CURSOR" $T; Add-Panel "  session token from Cursor's state.vscdb   " $M; Add-Panel "api/tot`n" $T
    Add-Panel "  COPILT" $T; Add-Panel "  PAT from config.json   " $M; Add-Panel "mo" $T
    Add-Panel " = AI credits used`n" $M
    Add-Panel "  OPENCD" $T; Add-Panel "  local spend, no quota API   " $M; Add-Panel "mo/all" $T
    Add-Panel " = `$ spent`n`n" $M

    Add-Panel "ERRORS`n" $H $true
    Add-Panel "  rate limited" $T; Add-Panel "=429   " $M
    Add-Panel "auth stale" $T; Add-Panel "=401   " $M
    Add-Panel "offline" $T; Add-Panel "=network`n" $M
    Add-Panel "  no token / no permission / check user" $T; Add-Panel " = fix config.json (COPILT)`n`n" $M

    Add-Panel "click to close" $M
}

$script:panelOpen = $false
function Set-PanelPosition {
    # force a layout pass now, since this runs before Show() and a stale
    # (e.g. zero) ActualHeight would make the below/above decision below
    # unreliable
    $panel.UpdateLayout()
    $wa = [System.Windows.SystemParameters]::WorkArea
    # align with the overlay; open below if there is room, otherwise above
    $panel.Left = [Math]::Max($wa.Left, [Math]::Min($window.Left, $wa.Right - $panel.ActualWidth))
    $panel.Top = if ($window.Top + $window.ActualHeight + 8 + $panel.ActualHeight -le $wa.Bottom) {
                     $window.Top + $window.ActualHeight + 8
                 } else { $window.Top - $panel.ActualHeight - 8 }
    # whatever was picked above, never let the panel land off-screen
    $panel.Top = [Math]::Max($wa.Top, [Math]::Min($panel.Top, $wa.Bottom - $panel.ActualHeight))
}
function Toggle-Panel {
    if ($script:panelOpen) {
        $panel.Hide()
        $script:panelOpen = $false
    } else {
        Set-PanelPosition
        $panel.Show()
        $panel.Topmost = $true
        $script:panelOpen = $true
    }
}
$btnWindow.Add_MouseLeftButtonDown({ Toggle-Panel })
$panel.Add_MouseLeftButtonDown({ Toggle-Panel })

$script:lastGood = @{}
$script:tick = -1

# Survive restarts: preload the last good numbers from disk, marked stale.
$cacheFile = Join-Path $dir 'usage-cache.json'
if (Test-Path $cacheFile) {
    try {
        $saved = Get-Content $cacheFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            $p.Value.stale = $true
            $script:lastGood[$p.Name] = $p.Value
        }
    } catch {}
}

# ---------- background fetching ----------
#
# Fetches (HTTP calls, node.exe spawns) used to run on the UI thread, freezing
# the overlay for up to ~8s per API on a bad network. They now run in a
# background runspace pool; only the fast redraw touches WPF. Shared state
# ($lastGood, $inflight) is read/written solely from DispatcherTimer ticks,
# which run on the UI thread, so no locking is needed.

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($v in @{ dir = $dir; nodeExe = $nodeExe; cfg = $cfg }.GetEnumerator()) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry $v.Key, $v.Value, ''))
}
foreach ($fnName in 'Get-HttpErrLabel', 'Get-ClaudeUsage', 'Get-CodexUsage', 'Get-CursorUsage', 'Get-CopilotUsage', 'Get-OpenCodeUsage') {
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry $fnName, (Get-Command $fnName).Definition))
}
$pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
$pool.Open()
$script:inflight = @{}   # key -> @{ ps; handle }

# Merge one finished fetch into $lastGood, keeping the last good value on
# failure (flagged stale so the UI marks it amber).
function Merge-Result([string]$key, $d) {
    if ($null -ne $d -and $d.ok) {
        $d.stale = $false
        $script:lastGood[$key] = $d
    } elseif ($script:lastGood.ContainsKey($key)) {
        $script:lastGood[$key].stale = $true
    } elseif ($null -ne $d) {
        $script:lastGood[$key] = $d   # first fetch failed, nothing cached yet
    }
}

# Kick off background fetches for every due provider not already in flight.
# Remote providers run only when $remoteDue; local reads run every time.
function Start-Fetch([bool]$remoteDue) {
    foreach ($p in $enabledProviders) {
        $due = if ($p.remote) { $remoteDue } else { $true }
        if (-not $due) { continue }
        if ($script:inflight.ContainsKey($p.key)) { continue }
        try {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddCommand($p.fn)
            $script:inflight[$p.key] = @{ ps = $ps; handle = $ps.BeginInvoke() }
        } catch {}
    }
}

# Collect finished fetches, merge them, and redraw. Runs often and cheaply.
$collector = New-Object System.Windows.Threading.DispatcherTimer
$collector.Interval = [TimeSpan]::FromMilliseconds(200)
$collector.Add_Tick({
    $any = $false
    foreach ($key in @($script:inflight.Keys)) {
        $job = $script:inflight[$key]
        if (-not $job.handle.IsCompleted) { continue }
        $result = $null
        try {
            # EndInvoke returns a PSDataCollection, which is a consuming stream:
            # index it twice and the second read is empty. Snapshot it into a
            # plain array once, then only touch the array. The item comes back
            # usable as a hashtable directly (no PSObject unwrap needed).
            $outArr = @($job.ps.EndInvoke($job.handle))
            if ($outArr.Count -gt 0) { $result = $outArr[0] }
        } catch { $result = @{ ok = $false; err = 'offline' } }
        try { $job.ps.Dispose() } catch {}
        $script:inflight.Remove($key)
        Merge-Result $key $result
        $any = $true
    }
    if ($any) { Draw }
})

# Draw the overlay from whatever is currently in $lastGood (fast, UI thread).
function Draw {
    $body.Inlines.Clear()
    $first = $true
    $anyStale = $false
    foreach ($p in $enabledProviders) {
        if (-not $script:lastGood.ContainsKey($p.key)) { continue }
        $data = $script:lastGood[$p.key]
        if (-not $first) { Add-Run "`n" '#E6EDF3' }
        $first = $false
        if (-not $data.ok) {
            Add-Run ("{0}  {1}" -f $p.name, $data.err) '#8B949E'
            continue
        }
        $nameColor = '#8B949E'
        if ($data.stale) { $nameColor = '#E3B341'; $anyStale = $true }
        # Text-only sections (e.g. OpenCode spend): no bar/% columns.
        if ($data.textRows) {
            $rowIdx = 0
            foreach ($t in $data.textRows) {
                $prefix = if ($rowIdx -eq 0) { $p.name } else { '      ' }
                Add-Run ("{0} " -f $prefix) $nameColor
                Add-Run $t '#C9D1D9'
                if ($rowIdx -lt $data.textRows.Count - 1) { Add-Run "`n" '#E6EDF3' }
                $rowIdx++
            }
            continue
        }
        $rowIdx = 0
        foreach ($row in $data.rows) {
            $prefix = if ($rowIdx -eq 0) { $p.name } else { '      ' }
            Add-Run ("{0} " -f $prefix) $nameColor
            Add-Run ($row.Label + ' ') '#8B949E'
            Add-Run (Get-Bar $row.Pct) (Get-PctColor $row.Pct)
            Add-Run (" {0,3:N0}% " -f $row.Pct) (Get-PctColor $row.Pct)
            Add-Run ("r " + (Format-Reset $row.Resets)) '#8B949E'
            if ($rowIdx -lt $data.rows.Count - 1) { Add-Run "`n" '#E6EDF3' }
            $rowIdx++
        }
    }
    Add-Run ("`n" + (Get-Date -Format 'HH:mm') + ' refreshed') '#484F58'
    if ($anyStale) { Add-Run ' / amber = cached' '#E3B341' }

    try { $script:lastGood | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding utf8 } catch {}
}

# One tick: start any due fetches, then redraw from current data. Results that
# arrive later trigger their own redraw via the collector.
function Render {
    $script:tick++
    Start-Fetch ($script:tick % 3 -eq 0)
    Draw
}

function Set-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    # a dragged position (saved as x/y in config.json) wins over the corner,
    # but is clamped to the current work area so a monitor change (or a
    # corrupted value) can never push the click-through overlay off-screen
    # with no way to grab it back
    $savedX = if ($cfg.ContainsKey('x')) { try { [double]$cfg.x } catch { $null } } else { $null }
    $savedY = if ($cfg.ContainsKey('y')) { try { [double]$cfg.y } catch { $null } } else { $null }
    if ($null -ne $savedX -and $null -ne $savedY) {
        $window.Left = [Math]::Max($wa.Left, [Math]::Min($savedX, $wa.Right - $window.ActualWidth))
        $window.Top = [Math]::Max($wa.Top, [Math]::Min($savedY, $wa.Bottom - $window.ActualHeight))
    } else {
        $window.Left = if ($cfg.corner -like '*-left') { $wa.Left + $cfg.marginX }
                       else { $wa.Right - $window.ActualWidth - $cfg.marginX }
        $window.Top = if ($cfg.corner -like 'bottom-*') { $wa.Bottom - $window.ActualHeight - $cfg.marginY }
                      else { $wa.Top + $cfg.marginY }
    }
    # "?" button (30px hit area) sits beside the overlay's top row, on
    # whichever side has room
    $btnWindow.Left = if ($window.Left - 34 -ge $wa.Left) { $window.Left - 34 }
                      else { $window.Left + $window.ActualWidth + 4 }
    $btnWindow.Top = $window.Top - 4
    if ($script:panelOpen) { Set-PanelPosition }
}

# Persist the current window position into config.json, keeping any other
# keys the user has set there. If the file can't be read back (a hand-edit
# left invalid JSON), we skip the write rather than overwrite it with only
# x/y and silently lose the rest of the user's settings (token included).
function Save-Config {
    $obj = [ordered]@{}
    if (Test-Path $cfgFile) {
        try {
            (Get-Content $cfgFile -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $obj[$_.Name] = $_.Value }
        } catch {
            return
        }
    }
    $obj['x'] = $cfg.x
    $obj['y'] = $cfg.y
    try { $obj | ConvertTo-Json | Set-Content -Path $cfgFile -Encoding utf8 } catch {}
}

$window.Add_ContentRendered({ Set-Position })
$window.Add_SizeChanged({ Set-Position })

# Ctrl+drag to move: while Ctrl is held the overlay stops being
# click-through so it can catch the mouse; releasing Ctrl restores it.
$script:interactive = $false
$ctrlTimer = New-Object System.Windows.Threading.DispatcherTimer
$ctrlTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$ctrlTimer.Add_Tick({
    $ctrlDown = ([Win32Ex]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    if ($ctrlDown -ne $script:interactive) {
        $script:interactive = $ctrlDown
        Set-ClickThrough $window (-not $ctrlDown)
        $window.Cursor = if ($ctrlDown) { [System.Windows.Input.Cursors]::SizeAll } else { $null }
    }
})
$ctrlTimer.Start()

$window.Add_MouseLeftButtonDown({
    if (-not $script:interactive) { return }
    $startLeft = $window.Left
    $startTop = $window.Top
    try { $window.DragMove() } catch {}
    # a Ctrl+click with no real movement (e.g. Ctrl held for an unrelated
    # reason) must not switch the overlay into fixed-position mode
    if ($window.Left -eq $startLeft -and $window.Top -eq $startTop) { return }
    # remember where it was dropped, across restarts
    $cfg['x'] = [Math]::Round($window.Left)
    $cfg['y'] = [Math]::Round($window.Top)
    Save-Config
    Set-Position
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($cfg.refreshSeconds)
$timer.Add_Tick({ try { Render } catch {} })

$window.Add_Loaded({
    try { Render } catch {}
    $timer.Start()
    $collector.Start()
})

Build-Panel

$window.Show()
$btnWindow.Show()
$panel.Show(); $panel.Hide()   # realize handle + ex-style, then keep hidden
Set-Position

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$window.Add_Closed({ $app.Shutdown() })

# ---------- tray icon ----------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Custom renderer so the tray menu matches the overlay: dark background, light
# text always (so the hovered item stays readable), subtle gray highlight.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Drawing;
using System.Windows.Forms;
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    static Color Bg    = Color.FromArgb(13, 17, 23);
    static Color Hover = Color.FromArgb(48, 54, 61);
    static Color Text  = Color.FromArgb(201, 209, 217);
    static Color Line  = Color.FromArgb(60, 66, 74);
    public DarkMenuRenderer() : base(new DarkColors()) { }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Rectangle r = new Rectangle(Point.Empty, e.Item.Size);
        using (SolidBrush b = new SolidBrush(e.Item.Selected ? Hover : Bg)) e.Graphics.FillRectangle(b, r);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = Text;   // always light, so the highlighted row stays legible
        base.OnRenderItemText(e);
    }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        using (SolidBrush b = new SolidBrush(Bg)) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        Rectangle r = e.AffectedBounds; r.Width--; r.Height--;
        using (Pen p = new Pen(Line)) e.Graphics.DrawRectangle(p, r);
    }
}
public class DarkColors : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(13, 17, 23); } }
}
"@

$notify = New-Object System.Windows.Forms.NotifyIcon
# A small usage-meter icon (green/amber/red bars) instead of the generic "i".
$script:trayBmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($script:trayBmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)
$bars = @(
    @{ x = 4;  h = 11; c = [System.Drawing.Color]::FromArgb(126, 231, 135) },  # green
    @{ x = 13; h = 17; c = [System.Drawing.Color]::FromArgb(227, 179, 65) },   # amber
    @{ x = 22; h = 24; c = [System.Drawing.Color]::FromArgb(255, 123, 114) }   # red
)
foreach ($b in $bars) {
    $brush = New-Object System.Drawing.SolidBrush $b.c
    $g.FillRectangle($brush, [int]$b.x, [int](28 - $b.h), 6, [int]$b.h)
    $brush.Dispose()
}
$g.Dispose()
$script:trayIcon = [System.Drawing.Icon]::FromHandle($script:trayBmp.GetHicon())
$notify.Icon = $script:trayIcon
$notify.Text = 'usage overlay'
$notify.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Renderer = New-Object DarkMenuRenderer
$trayMenu.ShowImageMargin = $false   # drop the empty icon gutter on the left
$trayMenu.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$trayMenu.ForeColor = [System.Drawing.Color]::FromArgb(201, 209, 217)
$null = $trayMenu.Items.Add('Refresh now', $null, { try { Start-Fetch $true; Draw } catch {} })
$null = $trayMenu.Items.Add('Restart', $null, {
    # a single quoted string, not an array: PowerShell 5.1's Start-Process
    # joins ArgumentList array elements with spaces but does NOT quote them,
    # so an install path containing a space would otherwise split in two
    $scriptPath = Join-Path $dir 'usage-overlay.ps1'
    Start-Process powershell -ArgumentList "-WindowStyle Hidden -File `"$scriptPath`"" -WindowStyle Hidden
})
$null = $trayMenu.Items.Add('Exit', $null, { $app.Shutdown() })
foreach ($it in $trayMenu.Items) {
    $it.ForeColor = [System.Drawing.Color]::FromArgb(201, 209, 217)
    $it.Padding = New-Object System.Windows.Forms.Padding(4, 2, 12, 2)
}
$notify.ContextMenuStrip = $trayMenu

$app.Run() | Out-Null
$notify.Visible = $false
$notify.Dispose()
try { $pool.Close(); $pool.Dispose() } catch {}
Remove-Item $pidFile -ErrorAction SilentlyContinue
