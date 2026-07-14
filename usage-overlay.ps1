# usage-overlay.ps1
# Floating click-through overlay showing Claude Code + Codex usage windows.
# Run:  powershell -WindowStyle Hidden -File usage-overlay.ps1
# Stop: powershell -File stop-overlay.ps1   (or kill the PID in usage-overlay.pid)

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

# With "auto", a section is kept only if its tool left data on this machine,
# so tools you don't use don't show up as permanent errors.
$hasCopilotConfig = ("$($cfg.githubToken)" -ne '' -and "$($cfg.githubUser)" -ne '')
$detected = [ordered]@{
    claude   = (Test-Path "$env:USERPROFILE\.claude\.credentials.json")
    codex    = (Test-Path "$env:USERPROFILE\.codex\sessions")
    cursor   = (Test-Path "$env:APPDATA\Cursor\User\globalStorage\state.vscdb")
    copilot  = $hasCopilotConfig
    opencode = (Test-Path "$env:USERPROFILE\.local\share\opencode\opencode.db")
}
if ("$($cfg.sections)" -eq 'auto') {
    $enabledSections = @($detected.Keys | Where-Object { $detected[$_] })
    # nothing detected at all: show everything except copilot, which needs
    # a token nobody has typed in yet and would otherwise show a permanent
    # error with no local trace of the tool to justify it
    if (-not $enabledSections) { $enabledSections = @($detected.Keys | Where-Object { $_ -ne 'copilot' }) }
} else {
    $enabledSections = @($cfg.sections | ForEach-Object { "$_".ToLower() })
}

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

# Fetch when due; otherwise (or on failure) fall back to the last good
# result, flagged stale so the UI can mark it with *.
function Update-Source([string]$key, [scriptblock]$fetch, [bool]$due) {
    if ($due -or -not $script:lastGood.ContainsKey($key)) {
        $d = & $fetch
        if ($d.ok) {
            $d.stale = $false
            $script:lastGood[$key] = $d
            return $d
        }
        if ($script:lastGood.ContainsKey($key)) {
            $c = $script:lastGood[$key]
            $c.stale = $true
            return $c
        }
        return $d
    }
    return $script:lastGood[$key]
}

function Render {
    $script:tick++
    # Codex is a local file read: every tick. Claude and Cursor hit remote
    # APIs that rate-limit: every 3rd tick (3 min).
    $remoteDue = ($script:tick % 3 -eq 0)
    $specs = @(
        @{ key = 'claude';   name = 'CLAUDE'; fetch = ${function:Get-ClaudeUsage};   due = $remoteDue },
        @{ key = 'codex';    name = 'CODEX '; fetch = ${function:Get-CodexUsage};    due = $true },
        @{ key = 'cursor';   name = 'CURSOR'; fetch = ${function:Get-CursorUsage};   due = $remoteDue },
        @{ key = 'copilot';  name = 'COPILT'; fetch = ${function:Get-CopilotUsage};  due = $remoteDue },
        @{ key = 'opencode'; name = 'OPENCD'; fetch = ${function:Get-OpenCodeUsage}; due = $true }
    )

    $body.Inlines.Clear()
    $sections = @()
    foreach ($spec in $specs) {
        if ($enabledSections -contains $spec.key) {
            $sections += @{ name = $spec.name; data = (Update-Source $spec.key $spec.fetch $spec.due) }
        }
    }
    $first = $true
    $anyStale = $false
    foreach ($s in $sections) {
        if (-not $first) { Add-Run "`n" '#E6EDF3' }
        $first = $false
        if (-not $s.data.ok) {
            Add-Run ("{0}  {1}" -f $s.name, $s.data.err) '#8B949E'
            continue
        }
        $nameColor = '#8B949E'
        if ($s.data.stale) { $nameColor = '#E3B341'; $anyStale = $true }
        # Text-only sections (e.g. OpenCode spend): no bar/% columns.
        if ($s.data.textRows) {
            $rowIdx = 0
            foreach ($t in $s.data.textRows) {
                $prefix = if ($rowIdx -eq 0) { $s.name } else { '      ' }
                Add-Run ("{0} " -f $prefix) $nameColor
                Add-Run $t '#C9D1D9'
                if ($rowIdx -lt $s.data.textRows.Count - 1) { Add-Run "`n" '#E6EDF3' }
                $rowIdx++
            }
            continue
        }
        $rowIdx = 0
        foreach ($row in $s.data.rows) {
            $prefix = if ($rowIdx -eq 0) { $s.name } else { '      ' }
            Add-Run ("{0} " -f $prefix) $nameColor
            Add-Run ($row.Label + ' ') '#8B949E'
            Add-Run (Get-Bar $row.Pct) (Get-PctColor $row.Pct)
            Add-Run (" {0,3:N0}% " -f $row.Pct) (Get-PctColor $row.Pct)
            Add-Run ("r " + (Format-Reset $row.Resets)) '#8B949E'
            if ($rowIdx -lt $s.data.rows.Count - 1) { Add-Run "`n" '#E6EDF3' }
            $rowIdx++
        }
    }
    Add-Run ("`n" + (Get-Date -Format 'HH:mm') + ' refreshed') '#484F58'
    if ($anyStale) { Add-Run ' / amber = cached' '#E3B341' }

    try { $script:lastGood | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding utf8 } catch {}
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
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = 'usage overlay'
$notify.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $trayMenu.Items.Add('Refresh now', $null, { try { Render } catch {} })
$null = $trayMenu.Items.Add('Restart', $null, {
    # a single quoted string, not an array: PowerShell 5.1's Start-Process
    # joins ArgumentList array elements with spaces but does NOT quote them,
    # so an install path containing a space would otherwise split in two
    $scriptPath = Join-Path $dir 'usage-overlay.ps1'
    Start-Process powershell -ArgumentList "-WindowStyle Hidden -File `"$scriptPath`"" -WindowStyle Hidden
})
$null = $trayMenu.Items.Add('Exit', $null, { $app.Shutdown() })
$notify.ContextMenuStrip = $trayMenu

$app.Run() | Out-Null
$notify.Visible = $false
$notify.Dispose()
Remove-Item $pidFile -ErrorAction SilentlyContinue
